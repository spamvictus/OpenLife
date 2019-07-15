package states.game;

import haxe.ds.Vector;
import data.PlayerData.PlayerType;
import console.Program;
import console.Console;
import data.MapData;
import data.MapData.MapInstance;
import data.PlayerData.PlayerInstance;
import data.PlayerData.PlayerMove;
import data.GameData;
import client.ClientTag;
import haxe.io.Bytes;

#if openfl
import openfl.display.FPS;
import openfl.display.DisplayObject;
import openfl.ui.Keyboard;
import ui.Text;
import settings.Bind;
#end

class Game #if openfl extends states.State #end
{
    #if openfl
    var dialog:Dialog;
    var ground:Ground;
    public var objects:Objects;
    public var cameraSpeed:Float = 10;
    public var info:Text;
    //camera
    public var cameraX:Int = 0;
    public var cameraY:Int = 0;
    public var sizeX:Int = 0;
    public var sizeY:Int = 0;
    //offset to 0 position
    public var offsetX:Int = 0;
    public var offsetY:Int = 0;
    //scale used for zoom in and out
    public var scale(get, set):Float;
    function get_scale():Float 
    {
        return scaleX;
    }
    
    function set_scale(scale:Float):Float 
    {
        scaleX = scale;
        scaleY = scale;
        center();
        return scale;
    }
    #end
    var playerInstance:PlayerInstance;
    public var mapInstance:MapInstance;
    var index:Int = 0;
    public var data:GameData;
    var compress:Bool = false;
    var inital:Bool = true;

    var program:Program;
    public function new()
    {
        program = new Program(this);
        //set interp
        Console.interp.variables.set("game",this);
        Console.interp.variables.set("program",program);
        data = new GameData();

        #if openfl
        super();
        ground = new Ground(this);
        objects = new Objects(this);
        dialog = new Dialog(this);
        addChild(ground);
        addChild(objects);
        addChild(dialog);
        info = new Text("GAME",LEFT,16,0xFFFFFF);
        Main.screen.addChild(info);
        Main.screen.addChild(new FPS(10,100,0xFFFFFF));
        #end
        //connect
        if(!true)
        {
            Main.client.login.accept = function()
            {
                trace("accept");
                //set message reader function to game
                Main.client.message = message;
                Main.client.end = end;
                Main.client.login = null;
                Main.client.tag = null;
            }
            Main.client.login.reject = function()
            {
                trace("reject");
                Main.client.login = null;
            }
            Main.client.login.email = "test@test.co.uk";
            Main.client.login.key = "WC2TM-KZ2FP-LW5A5-LKGLP";
            Main.client.message = Main.client.login.message;
            Main.client.ip = "game.krypticmedia.co.uk";
            Main.client.port = 8007;
            Main.client.connect();
        }else{
            //playground
            objects.size(Main.setWidth,Main.setHeight);

            setPlayer(cast(objects.add(19,0,0,true),Player));
            Player.main.instance = new PlayerInstance([]);
            Player.main.instance.move_speed = 3;
            data.playerMap.set(0,Player.main);

            objects.add(30,1,1);
            objects.add(575,2,2).animate(2);
        }
    }
    //client events
    #if openfl
    override function update()
    {
        info.text = cameraX + " " + cameraY + "\n" + objects.numTiles + "\nobjects " + objects.x + " " + objects.y;
        super.update();
        //controls
        var cameraArray:Array<DisplayObject> = [ground,objects];
        if (Bind.cameraUp.bool) for (obj in cameraArray) obj.y += cameraSpeed;
        if (Bind.cameraDown.bool) for (obj in cameraArray) obj.y += -cameraSpeed;
        if (Bind.cameraLeft.bool) for (obj in cameraArray) obj.x += cameraSpeed;
        if (Bind.cameraRight.bool) for (obj in cameraArray) obj.x += -cameraSpeed;

        if(Player.main != null)
        {
            var xs:Int = 0;
            var ys:Int = 0;
            if (Bind.playerUp.bool) ys += 1;
            if (Bind.playerDown.bool) ys += -1;
            if (Bind.playerLeft.bool) xs += -1;
            if (Bind.playerRight.bool) xs += 1;
            if (xs != 0 || ys != 0) Player.main.step(xs,ys);
            //animations
            if (Bind.playerDrop.bool) Player.main.animate(2);
            //grabs object where standing
            //if (Bind.playerPick.bool) 
        }
        //updates
        objects.update();
        //players
        var it = data.playerMap.iterator();
        while(it.hasNext())
        {
            it.next().update();
        }
    }
    public function mapUpdate() 
    {
        trace("MAP UPDATE");
        sizeX = mapInstance.sizeX;
        sizeY = mapInstance.sizeY;

        objects.size(sizeX,sizeY);

        offsetX = data.map.setX;
        offsetY = data.map.setY;
        cameraX = offsetX;
        cameraY = offsetY;

        for(j in 0...sizeY)
        {
            for (i in 0...sizeX)
            {
                trace("x " + Std.string(i + mapInstance.x) + " y " + Std.string(j + mapInstance.y));
                objects.addObject(data.map.object[j][i],i + mapInstance.x,j + mapInstance.y);
            }
        }
    }
    public function center()
    {
        x = (Main.setWidth - ground.width)/2 * scale;
        y = (Main.setHeight - ground.height)/2 * scale;
    }
    #end
    
    public function end()
    {
        switch(Main.client.tag)
        {
            case PLAYER_UPDATE:
            trace("set main");
            if (Player.main == null) 
            {
                setPlayer(objects.player);
            }
            objects.player = null;
            objects.sort();
            default:
        }
    }
    public function setPlayer(player:Player)
    {
        Player.main = player;
        Console.interp.variables.set("player",Player.main);
    }
    public function message(input:String) 
    {
        switch(Main.client.tag)
        {
            case PLAYER_UPDATE:
            playerInstance = new PlayerInstance(input.split(" "));
            objects.addPlayer(playerInstance);
            case PLAYER_MOVES_START:
            var playerMove = new PlayerMove(input.split(" "));
            if (data.playerMap.exists(playerMove.id))
            {
                playerMove.movePlayer(data.playerMap.get(playerMove.id));
            }
            case MAP_CHUNK:
            if(compress)
            {
                Main.client.tag = null;
                data.map.setRect(mapInstance.x,mapInstance.y,mapInstance.sizeX,mapInstance.sizeY,input);
                #if openfl
                mapUpdate();
                #end
                mapInstance = null;
                //toggle to go back to istance for next chunk
                compress = false;
            }else{
                var array = input.split(" ");
                //trace("map chunk array " + array);
                for(value in array)
                {
                    switch(index++)
                    {
                        case 0:
                        mapInstance = new MapInstance();
                        mapInstance.sizeX = Std.parseInt(value);
                        case 1:
                        mapInstance.sizeY = Std.parseInt(value);
                        case 2:
                        mapInstance.x = Std.parseInt(value);
                        case 3:
                        mapInstance.y = Std.parseInt(value);
                        case 4:
                        mapInstance.rawSize = Std.parseInt(value);
                        case 5:
                        mapInstance.compressedSize = Std.parseInt(value);
                        //set min
                        data.map.setX = mapInstance.x < data.map.setX ? mapInstance.x : data.map.setX;
                        data.map.setY = mapInstance.y < data.map.setY ? mapInstance.y : data.map.setY;
                        if (data.map.sizeX < mapInstance.x + mapInstance.sizeX) data.map.sizeX = mapInstance.x + mapInstance.sizeX;
                        if (data.map.sizeY < mapInstance.y + mapInstance.sizeY) data.map.sizeY = mapInstance.y + mapInstance.sizeY;
                        trace("map chunk " + mapInstance.toString());
                        index = 0;
                        //set compressed size wanted
                        Main.client.compress = mapInstance.compressedSize;
                        trace("set compress " + Main.client.compress);
                        compress = true;
                    }
                }
            }
            case MAP_CHANGE:
            //x y new_floor_id new_id p_id optional oldX oldY cameraSpeed
            var mapChange = new MapChange(input.split(" "));
            case HEAT_CHANGE:
            //trace("heat " + input);

            case FOOD_CHANGE:
            //trace("food change " + input);
            //also need to set new movement move_speed: is floating point cameraSpeed in grid square widths per second.
            case FRAME:
            Main.client.tag = "";
            case PLAYER_SAYS:
            trace("player say " + input);
            #if openfl
            dialog.say(input);
            #end
            case PLAYER_OUT_OF_RANGE:
            //player is out of range

            case LINEAGE:
            //p_id mother_id grandmother_id great_grandmother_id ... eve_id eve=eve_id

            case NAME:
            //p_id first_name last_name last_name may be ommitted.

            case DYING:
            //p_id isSick isSick is optional 1 flag to indicate that player is sick (client shouldn't show blood UI overlay for sick players)

            case HEALED:
            //p_id player healed no longer dying.

            case MONUMENT_CALL:
            //MN x y o_id monument call has happened at location x,y with the creation object id

            case GRAVE:
            //x y p_id

            case GRAVE_MOVE:
            //xs ys xd yd swap_dest optional swap_dest parameter is 1, it means that some other grave at  destination is in mid-air.  If 0, not

            case GRAVE_OLD:
            //x y p_id po_id death_age underscored_name mother_id grandmother_id great_grandmother_id ... eve_id eve=eve_id
            //Provides info about an old grave that wasn't created during your lifetime.
            //underscored_name is name with spaces replaced by _ If player has no name, this will be ~ character instead.

            case OWNER_LIST:
            //x y p_id p_id p_id ... p_id

            case VALLEY_SPACING:
            //y_spacing y_offset Offset is from client's birth position (0,0) of first valley.

            case FLIGHT_DEST:
            //p_id dest_x dest_y
            trace("FLIGHT FLIGHT FLIGHT " + input.split(" "));
            default:
        }
    }
}