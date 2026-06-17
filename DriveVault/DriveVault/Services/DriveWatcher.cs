using DriveVault.Data;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace DriveVault.Services
{
    public class DriveWatcher
    {
        public event Action<Drive>? DriveConnected;
        public event Action<Drive>? DriveDisconnected;
        public event Action? DataChanged;
        public event Action<Drive>? NewDriveDetected;
        public event Action<int, int, string>? IndexProgress;

        private Timer? _scanTimer;
        private Timer? _deepScanTimer;
        private bool _isRunning = false;
        private HashSet<string> _lastConnectedPaths = new();
        private bool _initialScanDone = false;
        private HashSet<string> _removedThisSession = new();
        private HashSet<string> _skippedDrives = new();
        private HashSet<string> _indexingDrives = new();
        private HashSet<string> _deepScanningDrives = new();

        public void Start()
        {
            if (_isRunning) return;
            _isRunning = true;
            DatabaseHelper.SetAllDrivesOffline();
            Task.Run(() =>
            {
                ScanConnectedDrives();
                _initialScanDone = true;
            });

            _scanTimer = new Timer(
                _ => { if (_initialScanDone) Task.Run(() => ScanConnectedDrives()); },
                null,
                TimeSpan.FromSeconds(5),
                TimeSpan.FromSeconds(5));

            _deepScanTimer = new Timer(
                _ => { if (_initialScanDone) Task.Run(() => DeepScanConnectedDrives()); },
                null,
                TimeSpan.FromSeconds(30),
                TimeSpan.FromSeconds(30));
        }

        public void Stop()
        {
            _isRunning = false;
            _scanTimer?.Dispose();
            _deepScanTimer?.Dispose();
        }

        public void MarkDriveRemoved(string mountPath)
        {
            _removedThisSession.Add(mountPath);
            _lastConnectedPaths.Remove(mountPath);
            _indexingDrives.Remove(mountPath);
            _deepScanningDrives.Remove(mountPath);
        }

        public void MarkDriveSkipped(string mountPath)
        {
            _skippedDrives.Add(mountPath);
        }

        private void DeepScanConnectedDrives()
        {
            try
            {
                var drives = DatabaseHelper.GetAllDrives()
                    .Where(d => d.IsConnected && d.IsFullyIndexed)
                    .ToList();

                foreach (var drive in drives)
                {
                    if (_indexingDrives.Contains(drive.MountPath)) continue;
                    if (_deepScanningDrives.Contains(drive.MountPath)) continue;

                    _deepScanningDrives.Add(drive.MountPath);
                    try
                    {
                        bool changes = IndexDriveIncremental(drive);
                        if (changes) DataChanged?.Invoke();
                    }
                    finally
                    {
                        _deepScanningDrives.Remove(drive.MountPath);
                    }
                }
            }
            catch { }
        }

        public void ScanConnectedDrives()
        {
            try
            {
                var windowsDrives = DriveInfo.GetDrives()
                    .Where(d => d.IsReady &&
                           (d.DriveType == System.IO.DriveType.Removable ||
                            d.DriveType == System.IO.DriveType.Fixed) &&
                           !d.RootDirectory.FullName.StartsWith("C:\\",
                               StringComparison.OrdinalIgnoreCase))
                    .ToList();

                var currentPaths = windowsDrives
                    .Select(d => d.RootDirectory.FullName)
                    .ToHashSet();

                foreach (var p in _removedThisSession
                    .Where(p => !currentPaths.Contains(p)).ToList())
                    _removedThisSession.Remove(p);

                foreach (var p in _skippedDrives
                    .Where(p => !currentPaths.Contains(p)).ToList())
                    _skippedDrives.Remove(p);

                foreach (var p in _indexingDrives
                    .Where(p => !currentPaths.Contains(p)).ToList())
                    _indexingDrives.Remove(p);

                bool hasChanges = false;
                var existingDrives = DatabaseHelper.GetAllDrives();

                foreach (var dbDrive in existingDrives.Where(d => d.IsConnected))
                {
                    if (!currentPaths.Contains(dbDrive.MountPath))
                    {
                        if (_skippedDrives.Contains(dbDrive.MountPath) ||
                            !dbDrive.IsFullyIndexed)
                        {
                            DatabaseHelper.RemoveDrive(dbDrive.Id);
                            _lastConnectedPaths.Remove(dbDrive.MountPath);
                            _skippedDrives.Remove(dbDrive.MountPath);
                            _indexingDrives.Remove(dbDrive.MountPath);
                            _deepScanningDrives.Remove(dbDrive.MountPath);
                            hasChanges = true;
                            continue;
                        }

                        dbDrive.IsConnected = false;
                        DatabaseHelper.SaveDrive(dbDrive);
                        DatabaseHelper.LogActivity(
                            "drive_disconnected",
                            dbDrive.Id, "", dbDrive.Label, dbDrive.Label);
                        DriveDisconnected?.Invoke(dbDrive);
                        _lastConnectedPaths.Remove(dbDrive.MountPath);
                        _indexingDrives.Remove(dbDrive.MountPath);
                        _deepScanningDrives.Remove(dbDrive.MountPath);
                        hasChanges = true;
                    }
                }

                var autoIndex = DatabaseHelper.GetSetting("auto_index", "true") == "true";
                var askBefore = DatabaseHelper.GetSetting("ask_before_index", "false") == "true";
                var excludedRaw = DatabaseHelper.GetSetting("excluded_drives", "");
                var excluded = excludedRaw.Split(',')
                    .Select(s => s.Trim().ToLower())
                    .Where(s => !string.IsNullOrEmpty(s))
                    .ToHashSet();

                foreach (var wd in windowsDrives)
                {
                    try
                    {
                        var mountPath = wd.RootDirectory.FullName;
                        if (_removedThisSession.Contains(mountPath)) continue;

                        var serial = GetDriveSerial(mountPath);
                        var label = string.IsNullOrEmpty(wd.VolumeLabel)
                            ? mountPath.TrimEnd('\\')
                            : wd.VolumeLabel;

                        if (excluded.Contains(label.ToLower())) continue;

                        var existing = existingDrives.FirstOrDefault(
                            d => d.MountPath == mountPath);

                        if (_skippedDrives.Contains(mountPath) && existing != null)
                        {
                            DatabaseHelper.RemoveDrive(existing.Id);
                            existingDrives.Remove(existing);
                            existing = null;
                        }

                        bool isBrandNew = existing == null;

                        var drive = existing ?? new Drive
                        {
                            Id = Guid.NewGuid().ToString(),
                            SerialNumber = serial,
                            FirstSeen = DateTime.Now,
                            IsFullyIndexed = false
                        };

                        drive.Label = label;
                        drive.MountPath = mountPath;
                        drive.TotalBytes = wd.TotalSize;
                        drive.UsedBytes = wd.TotalSize - wd.AvailableFreeSpace;
                        drive.DriveType = DetectDriveType(wd);
                        drive.IsConnected = true;
                        drive.LastSeen = DateTime.Now;

                        DatabaseHelper.SaveDrive(drive);

                        bool justConnected = !_lastConnectedPaths.Contains(mountPath);

                        if (justConnected)
                        {
                            DatabaseHelper.LogActivity(
                                "drive_connected",
                                drive.Id, "", drive.Label, drive.Label);

                            if (isBrandNew || _skippedDrives.Contains(mountPath))
                            {
                                NewDriveDetected?.Invoke(drive);
                            }
                            else if (askBefore && !drive.IsFullyIndexed)
                            {
                                NewDriveDetected?.Invoke(drive);
                            }
                            else if (autoIndex && !drive.IsFullyIndexed &&
                                     !_indexingDrives.Contains(mountPath))
                            {
                                _indexingDrives.Add(mountPath);
                                Task.Run(() =>
                                {
                                    IndexDriveFull(drive);
                                    _indexingDrives.Remove(mountPath);
                                });
                            }
                            else if (autoIndex && drive.IsFullyIndexed)
                            {
                                Task.Run(() =>
                                {
                                    bool changes = IndexDriveIncremental(drive);
                                    if (changes) DataChanged?.Invoke();
                                });
                            }

                            DriveConnected?.Invoke(drive);
                            hasChanges = true;
                        }
                    }
                    catch { }
                }

                _lastConnectedPaths = currentPaths
                    .Where(p => !_removedThisSession.Contains(p))
                    .ToHashSet();

                if (hasChanges) DataChanged?.Invoke();
            }
            catch { }
        }

        private static string GetDriveSerial(string drivePath)
        {
            try
            {
                var root = drivePath.TrimEnd('\\');
                uint serialNumber = 0;
                uint maxComponentLen = 0;
                uint fileSystemFlags = 0;

                bool success = GetVolumeInformation(
                    root + "\\", null, 0,
                    ref serialNumber,
                    ref maxComponentLen,
                    ref fileSystemFlags,
                    null, 0);

                if (success && serialNumber != 0)
                    return serialNumber.ToString("X8");
            }
            catch { }
            return drivePath.Substring(0, 1).ToUpper();
        }

        [System.Runtime.InteropServices.DllImport("kernel32.dll",
            CharSet = System.Runtime.InteropServices.CharSet.Auto,
            SetLastError = true)]
        private static extern bool GetVolumeInformation(
            string rootPathName,
            System.Text.StringBuilder? volumeNameBuffer,
            int volumeNameSize,
            ref uint volumeSerialNumber,
            ref uint maximumComponentLength,
            ref uint fileSystemFlags,
            System.Text.StringBuilder? fileSystemNameBuffer,
            int fileSystemNameSize);

        private static string DetectDriveType(DriveInfo drive)
        {
            if (drive.DriveType == System.IO.DriveType.Removable) return "Removable";
            if (drive.DriveType == System.IO.DriveType.Fixed) return "HDD";
            return "Unknown";
        }

        // ─── Full Index ───────────────────────────────────────────
        public void IndexDriveFull(Drive drive)
        {
            try
            {
                System.Diagnostics.Debug.WriteLine($"IndexDriveFull called: {drive.Label} — Connected: {drive.IsConnected} — MountPath: {drive.MountPath}");
                var oldFolders = DatabaseHelper.GetFoldersByDrive(drive.Id);
                foreach (var old in oldFolders)
                    DatabaseHelper.DeleteFolder(old.Id);

                var topFolders = Directory.GetDirectories(drive.MountPath)
                    .Where(f =>
                    {
                        var name = Path.GetFileName(f);
                        return !name.StartsWith("$") &&
                               !name.StartsWith(".") &&
                               !name.Equals("System Volume Information",
                                   StringComparison.OrdinalIgnoreCase) &&
                               !name.Equals("Recovery",
                                   StringComparison.OrdinalIgnoreCase) &&
                               !name.Equals("$RECYCLE.BIN",
                                   StringComparison.OrdinalIgnoreCase);
                    }).ToArray();

                int total = topFolders.Length;
                int current = 0;

                foreach (var folderPath in topFolders)
                {
                    try
                    {
                        current++;
                        var folderName = Path.GetFileName(folderPath);
                        IndexProgress?.Invoke(current, total, folderName);

                        var allFiles = new DirectoryInfo(folderPath)
                            .EnumerateFiles("*", SearchOption.AllDirectories)
                            .ToList();

                        var topFolder = new DriveFolder
                        {
                            Id = Guid.NewGuid().ToString(),
                            DriveId = drive.Id,
                            FolderName = folderName,
                            FolderPath = folderPath,
                            SizeBytes = allFiles.Sum(f => f.Length),
                            FileCount = allFiles.Count,
                            FileTypeSummary = GetFileTypeSummary(allFiles),
                            FirstSeen = Directory.GetCreationTime(folderPath),
                            LastSeen = DateTime.Now,
                            IsTopLevel = true
                        };
                        DatabaseHelper.SaveFolder(topFolder);

                        DatabaseHelper.LogActivity(
                            "folder_added", drive.Id,
                            topFolder.Id, folderName, drive.Label,
                            topFolder.FileTypeSummary,
                            topFolder.FileCount,
                            topFolder.SizeBytes);

                        IndexSubFolders(drive, folderPath, 1);
                    }
                    catch { }
                }

                drive.IsFullyIndexed = true;
                DatabaseHelper.SaveDrive(drive);
                DatabaseHelper.LogActivity(
                    "drive_reindexed", drive.Id, "", drive.Label, drive.Label);
                DataChanged?.Invoke();
            }
            catch { }
        }

        // ✅ Used only during full index — always creates new records
        private void IndexSubFolders(Drive drive, string parentPath, int depth)
        {
            if (depth > 3) return;

            try
            {
                var subDirs = Directory.GetDirectories(parentPath)
                    .Where(f =>
                    {
                        var name = Path.GetFileName(f);
                        return !name.StartsWith("$") &&
                               !name.StartsWith(".");
                    }).ToArray();

                foreach (var subPath in subDirs)
                {
                    try
                    {
                        var subFiles = new DirectoryInfo(subPath)
                            .EnumerateFiles("*", SearchOption.AllDirectories)
                            .ToList();

                        var subFolder = new DriveFolder
                        {
                            Id = Guid.NewGuid().ToString(),
                            DriveId = drive.Id,
                            FolderName = Path.GetFileName(subPath),
                            FolderPath = subPath,
                            SizeBytes = subFiles.Sum(f => f.Length),
                            FileCount = subFiles.Count,
                            FileTypeSummary = GetFileTypeSummary(subFiles),
                            FirstSeen = Directory.GetCreationTime(subPath),
                            LastSeen = DateTime.Now,
                            IsTopLevel = false
                        };
                        DatabaseHelper.SaveFolder(subFolder);

                        IndexSubFolders(drive, subPath, depth + 1);
                    }
                    catch { }
                }
            }
            catch { }
        }

        // ✅ Used during incremental — checks existing DB before saving
        // Avoids duplicate GUID inserts that caused ArgumentException
        private void SyncSubFolders(Drive drive, string parentPath,
            Dictionary<string, DriveFolder> existingPaths,
            ref bool hasChanges, int depth = 1)
        {
            if (depth > 3) return;

            try
            {
                var subDirs = Directory.GetDirectories(parentPath)
                    .Where(f =>
                    {
                        var name = Path.GetFileName(f);
                        return !name.StartsWith("$") &&
                               !name.StartsWith(".");
                    }).ToArray();

                foreach (var subPath in subDirs)
                {
                    try
                    {
                        if (!existingPaths.ContainsKey(subPath))
                        {
                            // ✅ New subfolder — safe to create new record
                            var subFiles = new DirectoryInfo(subPath)
                                .EnumerateFiles("*", SearchOption.AllDirectories)
                                .ToList();

                            var subFolder = new DriveFolder
                            {
                                Id = Guid.NewGuid().ToString(),
                                DriveId = drive.Id,
                                FolderName = Path.GetFileName(subPath),
                                FolderPath = subPath,
                                SizeBytes = subFiles.Sum(f => f.Length),
                                FileCount = subFiles.Count,
                                FileTypeSummary = GetFileTypeSummary(subFiles),
                                FirstSeen = Directory.GetCreationTime(subPath),
                                LastSeen = DateTime.Now,
                                IsTopLevel = false
                            };
                            DatabaseHelper.SaveFolder(subFolder);
                            DatabaseHelper.LogActivity(
                                "folder_added", drive.Id,
                                subFolder.Id, subFolder.FolderName, drive.Label,
                                subFolder.FileTypeSummary,
                                subFolder.FileCount,
                                subFolder.SizeBytes);
                            existingPaths[subPath] = subFolder;
                            hasChanges = true;
                        }

                        // Recurse deeper to catch sub-subfolders
                        SyncSubFolders(drive, subPath,
                            existingPaths, ref hasChanges, depth + 1);
                    }
                    catch { }
                }
            }
            catch { }
        }

        // ─── Incremental Index ────────────────────────────────────
        public bool IndexDriveIncremental(Drive drive)
        {
            bool hasChanges = false;
            try
            {
                var existingFolders = DatabaseHelper.GetFoldersByDrive(drive.Id);
                var existingPaths = existingFolders
                    .ToDictionary(f => f.FolderPath, f => f);

                var topFolders = Directory.GetDirectories(drive.MountPath);
                var currentPaths = new HashSet<string>();

                foreach (var folderPath in topFolders)
                {
                    try
                    {
                        var folderName = Path.GetFileName(folderPath);
                        if (folderName.StartsWith("$") ||
                            folderName.StartsWith(".") ||
                            folderName.Equals("System Volume Information",
                                StringComparison.OrdinalIgnoreCase) ||
                            folderName.Equals("Recovery",
                                StringComparison.OrdinalIgnoreCase) ||
                            folderName.Equals("$RECYCLE.BIN",
                                StringComparison.OrdinalIgnoreCase)) continue;

                        currentPaths.Add(folderPath);

                        var allFiles = new DirectoryInfo(folderPath)
                            .EnumerateFiles("*", SearchOption.AllDirectories).ToList();

                        if (!existingPaths.ContainsKey(folderPath))
                        {
                            // Brand new top-level folder
                            var folder = new DriveFolder
                            {
                                Id = Guid.NewGuid().ToString(),
                                DriveId = drive.Id,
                                FolderName = folderName,
                                FolderPath = folderPath,
                                SizeBytes = allFiles.Sum(f => f.Length),
                                FileCount = allFiles.Count,
                                FileTypeSummary = GetFileTypeSummary(allFiles),
                                FirstSeen = Directory.GetCreationTime(folderPath),
                                LastSeen = DateTime.Now,
                                IsTopLevel = true
                            };
                            DatabaseHelper.SaveFolder(folder);
                            DatabaseHelper.LogActivity(
                                "folder_added", drive.Id,
                                folder.Id, folderName, drive.Label,
                                folder.FileTypeSummary,
                                folder.FileCount,
                                folder.SizeBytes);
                            existingPaths[folderPath] = folder;
                            // Index its subfolders (safe — folder is brand new)
                            IndexSubFolders(drive, folderPath, 1);
                            hasChanges = true;
                        }
                        else
                        {
                            var existing = existingPaths[folderPath];
                            var oldCount = existing.FileCount;
                            var newSize = allFiles.Sum(f => f.Length);
                            var newCount = allFiles.Count;
                            var newTypeSummary = GetFileTypeSummary(allFiles);

                            existing.SizeBytes = newSize;
                            existing.FileCount = newCount;
                            existing.FileTypeSummary = newTypeSummary;
                            existing.LastSeen = DateTime.Now;
                            DatabaseHelper.SaveFolder(existing);

                            if (newCount != oldCount)
                            {
                                var diff = newCount - oldCount;
                                DatabaseHelper.LogActivity(
                                    diff > 0 ? "files_added" : "files_removed",
                                    drive.Id, existing.Id, folderName, drive.Label,
                                    newTypeSummary,
                                    Math.Abs(diff),
                                    newSize);
                                hasChanges = true;
                            }

                            // ✅ CHANGE — use SyncSubFolders (checks DB first)
                            // NOT IndexSubFolders (always creates new records)
                            SyncSubFolders(drive, folderPath,
                                existingPaths, ref hasChanges);
                        }
                    }
                    catch { }
                }

                foreach (var existing in existingPaths.Values
                    .Where(f => f.IsTopLevel))
                {
                    if (!currentPaths.Contains(existing.FolderPath))
                    {
                        DatabaseHelper.DeleteFolder(existing.Id);
                        DatabaseHelper.LogActivity(
                            "folder_removed", drive.Id,
                            existing.Id, existing.FolderName, drive.Label,
                            existing.FileTypeSummary,
                            existing.FileCount,
                            existing.SizeBytes);
                        hasChanges = true;
                    }
                }

                if (hasChanges)
                    DatabaseHelper.LogActivity(
                        "drive_auto_indexed", drive.Id,
                        "", "Auto indexed", drive.Label);
            }
            catch { }
            return hasChanges;
        }

        private static string GetFileTypeSummary(List<FileInfo> files)
        {
            if (files.Count == 0) return "";
            return string.Join("|", files
                .GroupBy(f => f.Extension.ToLower())
                .OrderByDescending(g => g.Count())
                .Take(5)
                .Select(g =>
                {
                    var ext = string.IsNullOrEmpty(g.Key) ? "other" : g.Key;
                    return $"{g.Count()} {ext}";
                }));
        }
    }
}