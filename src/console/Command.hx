package console;

class Command
{
    var console:Console;
    public function new(console:Console)
    {
        this.console = console;
    }
    public function run(string:String):Bool
    {
        string = string.toLowerCase();
        switch(string)
        {
            case "exit":
            #if sys
            Sys.exit(0);
            #end
            case "reload":
            //hotreload

            //states
            case "menu":
            //go to menu

            case "game":
            //go to game
            case "clear":
            //clear display 

            //window
            case "fullscreen":
            Main.state.stage.window.fullscreen = !Main.state.stage.window.fullscreen;
            case "controls":
            //toggle controls
            case "borderless":
            Main.state.stage.window.borderless = !Main.state.stage.window.borderless;
            case "date":
            console.print("date",Date.now().toString());
            //urls
            case "github" | "code" | "source":
            url("https://github.com/pxshadow/openlife");
            case "techtree" | "tech" | "tree":
            url("https://onetech.info/");
            case "forums" | "forms" | "fourms" | "forum" | "form" | "fourm":
            url("https://onehouronelife.com/forums/");
            case "wiki":
            url("https://onehouronelife.gamepedia.com/One_Hour_One_Life_Wiki");
            default:
            return false;
        }
        return true;
    }
    public function url(string:String)
    {
        openfl.Lib.navigateToURL(new openfl.net.URLRequest(string));
    }
}