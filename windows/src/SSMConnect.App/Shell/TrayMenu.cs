using System.Windows.Controls;

namespace SSMConnect.App.Shell;

/// <summary>The tray's context menu: one item per shell action, each sending its helper command.</summary>
public static class TrayMenu
{
    public static ContextMenu Build(ShellController controller, Action showSettings, Action retry, Action quit)
    {
        var menu = new ContextMenu();
        foreach (var action in ShellController.MenuActions)
        {
            var item = new MenuItem { Header = action.Label, Tag = action.Command };
            item.Click += async (_, _) => await controller.RunAsync(action);
            menu.Items.Add(item);
        }
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("Settings…", "settings", showSettings));
        menu.Items.Add(Item("Retry Core", "retry", retry));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("Quit SSM Connect", "quit", quit));
        return menu;
    }

    static MenuItem Item(string header, string tag, Action action)
    {
        var item = new MenuItem { Header = header, Tag = tag };
        item.Click += (_, _) => action();
        return item;
    }
}
