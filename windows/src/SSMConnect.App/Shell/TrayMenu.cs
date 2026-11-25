using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace SSMConnect.App.Shell;

/// <summary>
/// The tray's context menu: the macOS menu's controls in its order, each named by its parity inventory
/// id (contracts/macos-parity.json) and shown, enabled and labelled as macOS shows it in the current
/// state. Each item asks the controller to operate its control; the menu holds no connection rules.
/// </summary>
public static class TrayMenu
{
    public static ContextMenu Build(ShellController controller, Action showSettings, Action retry, Action quit)
    {
        var menu = new ContextMenu();
        var items = new List<MenuItem>();
        MenuItem? forwardAnchor = null;
        var forwardItems = new List<MenuItem>();
        foreach (var control in ShellController.Controls.Where(c => c.Surface == "menu"))
        {
            var item = new MenuItem { Header = control.Label, Tag = control.Id };
            AutomationProperties.SetAutomationId(item, control.Id);
            menu.Items.Add(item);
            if (control.Command == "openForward")
            {
                forwardAnchor = item; // one item per local forward follows it
                item.Visibility = Visibility.Collapsed;
                continue;
            }
            // A submenu heading on macOS (VS Code Browser Routing, Advanced): the items it holds follow it.
            if (control.Shell.StartsWith("submenu", StringComparison.Ordinal)) item.IsHitTestVisible = false;
            else item.Click += async (_, _) => await controller.TriggerAsync(control.Id);
            items.Add(item);
        }
        menu.Items.Add(new Separator());
        var retryItem = new MenuItem { Header = "Retry Core", Tag = "retry" };
        retryItem.Click += (_, _) => retry();
        menu.Items.Add(retryItem);

        void Refresh()
        {
            foreach (var item in items)
            {
                var itemId = (string)item.Tag;
                item.Header = controller.LabelFor(itemId);
                item.Visibility = controller.IsOffered(itemId) ? Visibility.Visible : Visibility.Collapsed;
                item.IsEnabled = controller.IsEnabled(itemId);
            }
            if (forwardAnchor is null) return;
            foreach (var item in forwardItems) menu.Items.Remove(item);
            forwardItems.Clear();
            var forwards = controller.Details.TryGetValue("web.forwards", out var json) && !string.IsNullOrEmpty(json)
                ? JsonNode.Parse(json) as JsonArray ?? [] : [];
            var index = menu.Items.IndexOf(forwardAnchor);
            var id = (string)forwardAnchor.Tag;
            foreach (var forward in forwards.OfType<JsonObject>())
            {
                var context = new Dictionary<string, string> { ["item.openPath"] = (string?)forward["openPath"] ?? "" };
                if (!controller.IsOffered(id, context)) continue;
                var name = (string?)forward["name"] ?? "";
                var item = new MenuItem { Header = "Open " + name, Tag = id, IsEnabled = controller.IsEnabled(id, context) };
                AutomationProperties.SetAutomationId(item, id);
                item.Click += async (_, _) => await controller.TriggerAsync(id, new Dictionary<string, string> { ["name"] = name }, context);
                menu.Items.Insert(++index, item);
                forwardItems.Add(item);
            }
        }

        controller.ShowSettingsRequested += showSettings;
        controller.QuitRequested += quit;
        controller.DetailsChanged += () => menu.Dispatcher.BeginInvoke(Refresh);
        menu.Opened += (_, _) => Refresh();
        Refresh();
        return menu;
    }
}
