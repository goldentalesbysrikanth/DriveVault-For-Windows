using DriveVault.Data;
using DriveVault.Services;
using DriveVault.Views;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace DriveVault
{
    public sealed partial class MainWindow : Window
    {
        private DriveWatcher _driveWatcher = App.DriveWatcher;
        private CancellationTokenSource? _indexCts;
        private bool _isIndexing = false;
        private bool _isSearchNavigating = false;

        public MainWindow()
        {
            this.InitializeComponent();

            DatabaseHelper.InitializeDatabase();

            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
            var windowId = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hwnd);
            var appWindow = Microsoft.UI.Windowing.AppWindow.GetFromWindowId(windowId);
            appWindow.Resize(new Windows.Graphics.SizeInt32(1200, 750));
            appWindow.Closing += AppWindow_Closing;

            _driveWatcher.NewDriveDetected += (drive) =>
            {
                DispatcherQueue.TryEnqueue(async () =>
                {
                    try
                    {
                        var autoIndex = DatabaseHelper.GetSetting(
                            "auto_index", "true") == "true";
                        var askBefore = DatabaseHelper.GetSetting(
                            "ask_before_index", "false") == "true";

                        if (askBefore)
                        {
                            var dialog = new ContentDialog
                            {
                                Title = "New Drive Connected",
                                Content =
                                    $"\"{drive.Label}\" is connected.\n\n" +
                                    "Would you like to index this drive now?\n" +
                                    "This will scan all top-level folders.",
                                PrimaryButtonText = "Index Now",
                                SecondaryButtonText = "Later",
                                CloseButtonText = "Never ask again",
                                DefaultButton = ContentDialogButton.Primary,
                                XamlRoot = Content.XamlRoot
                            };

                            var result = await dialog.ShowAsync();

                            if (result == ContentDialogResult.Primary)
                            {
                                await RunIndexSafe(drive);
                                RefreshCurrentPage();
                            }
                            else if (result == ContentDialogResult.Secondary)
                            {
                                App.DriveWatcher.MarkDriveSkipped(drive.MountPath);
                                RefreshCurrentPage();
                            }
                            else if (result == ContentDialogResult.None)
                            {
                                DatabaseHelper.SaveSetting(
                                    "ask_before_index", "false");
                                RefreshCurrentPage();
                            }
                        }
                        else if (autoIndex)
                        {
                            await RunIndexSafe(drive);
                            RefreshCurrentPage();
                        }
                        else
                        {
                            RefreshCurrentPage();
                        }
                    }
                    catch { }
                });
            };

            _driveWatcher.DataChanged += () =>
            {
                DispatcherQueue.TryEnqueue(() =>
                {
                    try { RefreshCurrentPage(); } catch { }
                });
            };

            _driveWatcher.Start();
            CheckTrial();
            ApplyTheme();

            // ✅ NEW — start splash overlay animation
            DispatcherQueue.TryEnqueue(async () =>
            {
                await ShowSplashAsync();
            });
        }

        // ✅ NEW — animates the splash overlay then hides it
        // Plain language: logo fades in on top of the app,
        // holds for 2 seconds, then fades out revealing the real UI
        private async Task ShowSplashAsync()
        {
            try
            {
                // Small delay to ensure window is fully rendered
                await Task.Delay(100);

                // ── Fade in logo (0.6s) ───────────────────────────
                var fadeIn = new Storyboard();

                var overlayFadeIn = new DoubleAnimation
                {
                    From = 1,
                    To = 1,
                    Duration = new Duration(TimeSpan.FromSeconds(0.1))
                };
                Storyboard.SetTarget(overlayFadeIn, SplashOverlay);
                Storyboard.SetTargetProperty(overlayFadeIn, "Opacity");

                var scaleXIn = new DoubleAnimation
                {
                    From = 0.9,
                    To = 1.0,
                    Duration = new Duration(TimeSpan.FromSeconds(0.7)),
                    EasingFunction = new CubicEase
                    { EasingMode = EasingMode.EaseOut }
                };
                Storyboard.SetTarget(scaleXIn, SplashScale);
                Storyboard.SetTargetProperty(scaleXIn, "ScaleX");

                var scaleYIn = new DoubleAnimation
                {
                    From = 0.9,
                    To = 1.0,
                    Duration = new Duration(TimeSpan.FromSeconds(0.7)),
                    EasingFunction = new CubicEase
                    { EasingMode = EasingMode.EaseOut }
                };
                Storyboard.SetTarget(scaleYIn, SplashScale);
                Storyboard.SetTargetProperty(scaleYIn, "ScaleY");

                fadeIn.Children.Add(overlayFadeIn);
                fadeIn.Children.Add(scaleXIn);
                fadeIn.Children.Add(scaleYIn);
                fadeIn.Begin();

                // Hold
                await Task.Delay(2500);

                // ── Fade out overlay (0.6s) ───────────────────────
                var fadeOut = new Storyboard();

                var overlayFadeOut = new DoubleAnimation
                {
                    From = 1,
                    To = 0,
                    Duration = new Duration(TimeSpan.FromSeconds(0.6)),
                    EasingFunction = new CubicEase
                    { EasingMode = EasingMode.EaseIn }
                };
                Storyboard.SetTarget(overlayFadeOut, SplashOverlay);
                Storyboard.SetTargetProperty(overlayFadeOut, "Opacity");

                fadeOut.Children.Add(overlayFadeOut);
                fadeOut.Begin();

                await Task.Delay(650);

                // Collapse overlay so it doesn't block UI interaction
                SplashOverlay.Visibility = Visibility.Collapsed;
            }
            catch { }
        }

        private async Task RunIndexSafe(Data.Drive drive)
        {
            try
            {
                _indexCts = new CancellationTokenSource();
                _isIndexing = true;
                await Task.Run(() =>
                {
                    if (!_indexCts.Token.IsCancellationRequested)
                        App.DriveWatcher.IndexDriveFull(drive);
                }, _indexCts.Token);
            }
            catch (OperationCanceledException) { }
            catch { }
            finally
            {
                _isIndexing = false;
                _indexCts?.Dispose();
                _indexCts = null;
            }
        }

        private void AppWindow_Closing(
            Microsoft.UI.Windowing.AppWindow sender,
            Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
        {
            try
            {
                if (_isIndexing && _indexCts != null)
                {
                    _indexCts.Cancel();
                    _driveWatcher.Stop();
                    Task.Delay(300).Wait();
                }
                else
                {
                    _driveWatcher.Stop();
                }
            }
            catch { }
        }

        private void CheckTrial()
        {
            try
            {
                var activated = DatabaseHelper.GetSetting(
                    "license_activated", "false");
                if (activated == "true")
                {
                    NavView.SelectedItem = NavView.MenuItems[0];
                    ContentFrame.Navigate(typeof(OverviewPage));
                    return;
                }

                var installDate = DatabaseHelper.GetSetting("install_date", "");
                if (string.IsNullOrEmpty(installDate))
                {
                    installDate = DateTime.Now.ToString("o");
                    DatabaseHelper.SaveSetting("install_date", installDate);
                }

                if (!DateTime.TryParse(installDate, null,
                        DateTimeStyles.RoundtripKind, out var installed))
                {
                    installed = DateTime.Now;
                    DatabaseHelper.SaveSetting(
                        "install_date", installed.ToString("o"));
                }

                var daysLeft = 10 - (int)(DateTime.Now - installed).TotalDays;
                NavView.SelectedItem = NavView.MenuItems[0];

                if (daysLeft <= 0)
                {
                    var readOnly = DatabaseHelper.GetSetting(
                        "read_only_mode", "false");
                    if (readOnly == "true")
                        ContentFrame.Navigate(typeof(OverviewPage));
                    else
                    {
                        NavView.IsEnabled = false;
                        SearchBox.IsEnabled = false;
                        ContentFrame.Navigate(typeof(TrialExpiredPage));
                    }
                }
                else
                    ContentFrame.Navigate(typeof(OverviewPage));
            }
            catch
            {
                try
                {
                    NavView.SelectedItem = NavView.MenuItems[0];
                    ContentFrame.Navigate(typeof(OverviewPage));
                }
                catch { }
            }
        }

        private void NavView_SelectionChanged(NavigationView sender,
            NavigationViewSelectionChangedEventArgs args)
        {
            SearchBox.Text = "";
            SearchBox.ItemsSource = null;

            if (_isSearchNavigating) return;

            if (args.IsSettingsSelected)
            {
                ContentFrame.Navigate(typeof(SettingsPage));
                return;
            }

            if (args.SelectedItem is NavigationViewItem item)
            {
                var tag = item.Tag?.ToString();
                Type? pageType = tag switch
                {
                    "overview" => typeof(OverviewPage),
                    "drives" => typeof(DrivesPage),
                    "folders" => typeof(FoldersPage),
                    "clients" => typeof(ClientsPage),
                    "activity" => typeof(ActivityPage),
                    "settings" => typeof(SettingsPage),
                    _ => null
                };

                if (pageType != null)
                {
                    ContentFrame.Navigate(pageType);
                    while (ContentFrame.BackStackDepth > 0)
                        ContentFrame.BackStack.RemoveAt(0);
                }
            }
        }

        private void SearchBox_TextChanged(AutoSuggestBox sender,
            AutoSuggestBoxTextChangedEventArgs args)
        {
            if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput)
                return;

            var query = sender.Text.Trim().ToLower();
            if (string.IsNullOrWhiteSpace(query))
            {
                sender.ItemsSource = null;
                return;
            }

            try
            {
                var results = new List<SearchResult>();
                var drives = DatabaseHelper.GetAllDrives();
                var allFolders = new List<DriveFolder>();

                foreach (var drive in drives)
                    allFolders.AddRange(DatabaseHelper.GetFoldersByDrive(drive.Id));

                allFolders = allFolders
                    .GroupBy(f => f.Id)
                    .Select(g => g.First())
                    .ToList();

                foreach (var d in drives
                    .Where(d => d.Label.ToLower().Contains(query) ||
                                d.MountPath.ToLower().Contains(query)))
                    results.Add(new SearchResult
                    {
                        Title = d.Label,
                        Subtitle = $"Drive · {d.DriveType} · {d.MountPath}",
                        Tag = "drive:" + d.Id,
                        Icon = "🖴"
                    });

                foreach (var f in allFolders
                    .Where(f => f.FolderName.ToLower().Contains(query))
                    .Take(5))
                {
                    var drive = drives.FirstOrDefault(d => d.Id == f.DriveId);
                    var parentName = GetParentFolderName(
                        f.FolderPath, drive?.MountPath ?? "");
                    var location = string.IsNullOrEmpty(parentName)
                        ? drive?.Label ?? "Unknown"
                        : $"{drive?.Label ?? "Unknown"} › {parentName}";

                    results.Add(new SearchResult
                    {
                        Title = f.FolderName,
                        Subtitle = $"Library · {location} · {f.SizeDisplay} · {f.FileCount} files",
                        Tag = "folder:" + f.Id,
                        Icon = "📁"
                    });
                }

                foreach (var g in allFolders
                    .Where(f => f.FolderName.ToLower().Contains(query))
                    .GroupBy(f => f.FolderName)
                    .Take(5))
                {
                    var f = g.First();
                    var drive = drives.FirstOrDefault(d => d.Id == f.DriveId);
                    var total = g.Sum(x => x.SizeBytes);
                    var parentName = GetParentFolderName(
                        f.FolderPath, drive?.MountPath ?? "");
                    var location = string.IsNullOrEmpty(parentName)
                        ? drive?.Label ?? "Unknown"
                        : $"{drive?.Label ?? "Unknown"} › {parentName}";

                    results.Add(new SearchResult
                    {
                        Title = f.FolderName,
                        Subtitle = $"Client · {location} · {FormatSize(total)}",
                        Tag = "client:name:" + f.FolderName,
                        Icon = "👤"
                    });
                }

                sender.ItemsSource = results.Take(12).ToList();
            }
            catch { sender.ItemsSource = null; }
        }

        private async void SearchBox_SuggestionChosen(AutoSuggestBox sender,
            AutoSuggestBoxSuggestionChosenEventArgs args)
        {
            if (args.SelectedItem is not SearchResult result) return;

            sender.Text = "";
            sender.ItemsSource = null;

            try
            {
                if (result.Tag.StartsWith("drive:"))
                {
                    var driveId = result.Tag.Replace("drive:", "");
                    _isSearchNavigating = true;
                    NavigateToTab("drives");
                    await Task.Delay(150);
                    _isSearchNavigating = false;
                    ContentFrame.Navigate(typeof(DriveDetailPage), driveId);
                }
                else if (result.Tag.StartsWith("folder:"))
                {
                    var folderId = result.Tag.Replace("folder:", "");

                    _isSearchNavigating = true;
                    NavigateToTab("folders");
                    ContentFrame.Navigate(typeof(FoldersPage));
                    _isSearchNavigating = false;

                    await Task.Delay(200);

                    if (ContentFrame.Content is FoldersPage fp)
                        fp.LoadData(folderId);
                }
                else if (result.Tag.StartsWith("client:name:"))
                {
                    var folderName = result.Tag.Replace("client:name:", "");

                    _isSearchNavigating = true;
                    NavigateToTab("clients");

                    var tcs = new TaskCompletionSource<bool>();
                    void OnNavigated(object s,
                        Microsoft.UI.Xaml.Navigation.NavigationEventArgs e)
                    {
                        ContentFrame.Navigated -= OnNavigated;
                        tcs.TrySetResult(true);
                    }
                    ContentFrame.Navigated += OnNavigated;
                    ContentFrame.Navigate(typeof(ClientsPage));
                    _isSearchNavigating = false;

                    await Task.WhenAny(tcs.Task, Task.Delay(2000));

                    if (ContentFrame.Content is ClientsPage cp)
                        cp.LoadDataByName(folderName);
                }
            }
            catch { }
        }

        private void NavigateToTab(string tag)
        {
            foreach (var item in NavView.MenuItems)
            {
                if (item is NavigationViewItem navItem &&
                    navItem.Tag?.ToString() == tag)
                {
                    NavView.SelectedItem = navItem;
                    break;
                }
            }
        }

        private void RefreshCurrentPage()
        {
            try
            {
                if (ContentFrame.Content is OverviewPage op)
                    op.LoadData();
                else if (ContentFrame.Content is DrivesPage dp)
                    dp.LoadData();
                else if (ContentFrame.Content is FoldersPage fp)
                    fp.LoadData();
                else if (ContentFrame.Content is ClientsPage cp)
                    cp.LoadData();
            }
            catch { }
        }

        public void ApplyTheme()
        {
            var theme = DatabaseHelper.GetSetting("app_theme", "system");
            RootGrid.RequestedTheme = theme switch
            {
                "light" => ElementTheme.Light,
                "dark" => ElementTheme.Dark,
                _ => ElementTheme.Default
            };
        }

        private static string GetParentFolderName(
            string folderPath, string mountPath)
        {
            try
            {
                var mount = mountPath.TrimEnd('\\', '/');
                var path = folderPath.TrimEnd('\\', '/');
                var parent = System.IO.Path.GetDirectoryName(path) ?? "";
                parent = parent.TrimEnd('\\', '/');

                if (string.Equals(parent, mount,
                    StringComparison.OrdinalIgnoreCase))
                    return "";

                return System.IO.Path.GetFileName(parent);
            }
            catch { return ""; }
        }

        private static string FormatSize(long bytes)
        {
            if (bytes >= 1_099_511_627_776)
                return $"{bytes / 1_099_511_627_776.0:F1} TB";
            if (bytes >= 1_073_741_824)
                return $"{bytes / 1_073_741_824.0:F1} GB";
            if (bytes >= 1_048_576)
                return $"{bytes / 1_048_576.0:F1} MB";
            return $"{bytes / 1024.0:F1} KB";
        }
    }

    public class SearchResult
    {
        public string Title { get; set; } = "";
        public string Subtitle { get; set; } = "";
        public string Tag { get; set; } = "";
        public string Icon { get; set; } = "";
        public override string ToString() => $"{Icon}  {Title} — {Subtitle}";
    }
}