package game;
import data.map.MapData;
#if full
import console.Program.Pos;
import console.Program;
#end
import data.GameData;
#if openfl
import motion.easing.Sine;
import openfl.geom.Point;
import openfl.display.TileContainer;
import motion.easing.Quad;
import motion.easing.Linear;
import motion.MotionPath;
import motion.Actuate;
import openfl.display.Tile;
#end
import data.object.player.PlayerInstance;
import data.object.player.PlayerData;
import haxe.Timer;
import data.object.SpriteData;
import data.object.ObjectData;
import data.animation.AnimationData;
class Player #if openfl extends TileContainer #end
{
    #if openfl
    //statics
    private static inline var babyHeadDownFactor:Float = 0.6;
    private static inline var babyBodyDownFactor:Float = 0.75;
    private static inline var oldHeadDownFactor:Float = 0.35;
    private static inline var oldHeadForwardFactor:Float = 2;
    public var heldObject:TileContainer;
    //clothing hat;tunic;front_shoe;back_shoe;bottom;backpack
    var clothing:Array<Array<Tile>> = [];
    public var _sprites:Array<Tile> = [];
    #end
    public var instance:PlayerInstance;
    var clothingInt:Array<Int> = [];
    //pathing
    public var lastMove:Int = 1;
    public var moveTimer:Timer;
    public var moving:Bool = false;
    public var goal:Bool = false;
    #if full
    public var moves:Array<Pos> = [];
    public var program:Program = null;
    #end
    public var follow:Bool = true;
    var multi:Float = 1;
    //locally used instance pos
    public var ix:Int = 0;
    public var iy:Int = 0;
    //locally used object
    public var oid:Array<Int> = [];
    public var held:Bool = false;
    public var ageInt:Int = 0;
    //name
    public var firstName:String = "";
    public var lastName:String = "";
    public var text:String = "";
    public var inRange:Bool = true;
    public function new()
    {
        #if openfl
        super();
        #end
    }
    #if openfl
    public function getAgeHeadOffset(inAge:Float,head:Point,body:Point,frontFoot:Point)
    {
        if (inAge == -1) return new Point();
        var maxHead = head.y - body.y;
        if (inAge < 20)
        {
            var yOffset = ( ( 20 - inAge ) / 20 ) * babyHeadDownFactor * maxHead;
            return new Point(0,Math.round(-yOffset));
        }
        if (inAge >= 40)
        {
            if (inAge > 60)
            {
                inAge = 60;
            }
            var vertOffset = ( ( inAge - 40) / 20 ) * oldHeadDownFactor * maxHead;
            var footOffset = frontFoot.x - head.x;
            var forwardOffset = ( ( inAge - 40 ) / 20 ) * oldHeadDownFactor * footOffset;
            return new Point(Math.round(forwardOffset),Math.round(-vertOffset));
        }
        return new Point();
    }
    public function getAgeBodyOffset(inAge:Float,pos:Point)
    {
        if (inAge == -1) return new Point();
        if (inAge < 20)
        {
            var maxBody = pos.y;
            var yOffset = ( ( 20 - inAge) / 20) * babyBodyDownFactor * maxBody;
            return new Point(0,Math.round(-yOffset));
        }
        return new Point();
    }
    #end

    #if full
    public function motion()
    {
        //use another move
        if(moves.length > 0 && !moving)
        {
            var point = moves.pop();
            moving = true;
            var time = Std.int(Static.GRID/(Static.GRID * (instance.move_speed) * computePathSpeedMod()) * 60 * multi);
            #if !openfl
            #if (target.threaded)
            sys.thread.Thread.create(() -> {
                Sys.sleep(time/60);
                trace("finish move");
                ix += point.x;
                iy += point.y;
                moving = false;
                if (goal)
                {
                    path();
                }else{
                    motion();
                }
            });
            #end
            #else
            //facing direction
            if (point.x != 0)
            {
                if (point.x > 0)
                {
                    scaleX = 1;
                }else{
                    scaleX = -1;
                }
            }
            //animation
            Main.animations.play(instance.po_id,2,sprites(),0,Static.tileHeight);
            //move
            Actuate.tween(this,time/60,{x:(ix + point.x) * Static.GRID,y:(Static.tileHeight - (iy + point.y)) * Static.GRID}).onComplete(function(_)
            {
                ix += point.x;
                iy += point.y;
                moving = false;
                if (goal)
                {
                    path();
                }else{
                    motion();
                }
            }).ease(Linear.easeNone);
            #end
        }else{
            #if openfl
            //buffer
            if (Main.xs != 0 || Main.ys != 0) 
            {
                program.clean();
                step(Main.xs,Main.ys);
            }else{
                //no buffer
                Main.animations.clear(sprites());
            }
            #end
        }
    }
    public function step(mx:Int,my:Int):Bool
    {
        //no other move is occuring, and player is not moving on blocked
        if (moving || Main.data.blocking.get(Std.string(ix + mx) + "." + Std.string(iy + my))) return false;
        //send data
        lastMove++;
        //trace("step move " + mx + " " + my);
        Main.client.send("MOVE " + ix + " " + iy + " @" + lastMove + " " + mx + " " + my);
        var pos = new Pos();
        pos.x = mx;
        pos.y = my;
        moves = [pos];
        motion();
        return true;
    }
    public function computePathSpeedMod():Float
    {
        var floorData = Main.data.objectMap.get(Main.data.map.floor.get(ix,iy));
        var multiple:Float = 1;
        if (floorData != null) multiple *= floorData.speedMult;
        if (oid.length == 0) return multiple;
        var objectData = Main.data.objectMap.get(oid[0]);
        if (objectData != null) multiple *= objectData.speedMult;
        return multiple;
    }
    public function measurePathLength():Float
    {
        var diagLength:Float = 1.4142356237;
        var totalLength:Float = 0;
        if (moves.length < 2)
        {
            return totalLength;
        }
        var lastPos = moves[0];
        for (i in 1...moves.length)
        {
            if (moves[i].x != lastPos.x && moves[i].y != lastPos.y)
            {
                totalLength += diagLength;
            }else{
                //not diag
                totalLength += 1;
            }
            lastPos = moves[i];
        }
        return totalLength;
    }
    public function equal(pos:Pos,pos2:Pos):Bool
    {
        if (pos.x == pos2.x && pos.y == pos2.y) return true;
        return false;
    }
    public function sub(pos:Pos,pos2:Pos):Pos
    {
        var pos = new Pos();
        pos.x = pos.x - pos2.x;
        pos.y = pos.y - pos2.y;
        return pos;
    }
    public var px:Int = 0;
    public var py:Int = 0;
    public function path()
    {
        if (!setPath())
        {
            //complete
            program.end();
            return;
        }
        pathfind(px,py);
    }
    public function setPath():Bool
    {
        if (program.goal == null) return false;
        px = program.goal.x - ix;
        py = program.goal.y - iy;
        var bool:Bool = false;
        if (px != 0) 
        {
            px = px > 0 ? 1 : -1;
            bool = true;
        }
        if (py != 0)
        {
            py = py > 0 ? 1 : -1;
            bool = true;
        }
        return bool;
    }
    public function pathfind(px:Int,py:Int)
    {
        if (!step(px,py))
        {
            //non direct path
            if (px == py || px == py * -1)
            {
                //diagnol
                if (!step(px,0)) step(0,py);
            }else{
                //non diagnol
                if (px == 0)
                {
                    //vetical
                    if (!step(1,py)) step(-1,py);
                }else{
                    //horizontal
                    if (!step(px,1)) step(px,-1);
                }
            }
        }
    }
    #end
    public function force() 
    {
        #if full
        moves = [];
        #end
        moving = false;
        #if openfl
        Actuate.pause(this);
        //local position
        x = instance.x * Static.GRID;
        y = (Static.tileHeight - instance.y) * Static.GRID;
        #end
    }
    public function set(data:PlayerInstance)
    {
        if (instance == null)
        {
            ix = data.x;
            iy = data.y;
        }
        instance = data;
        //pos and age
        if (instance.forced) 
        {
            trace("force!");
            if (held)
            {
                //added back to stage
                #if openfl
                Main.objects.group.addTile(this);
                #end
                held = false;
            }
            ix = instance.x;
            iy = instance.y;
            #if full
            Main.client.send("FORCE " + ix + " " + iy);
            if (program != null) program.clean();
            #end
            //force movement
            force();
        }
        //remove moves
        #if full
        moves = [];
        #end
        #if openfl
        age();
        #end
        hold();
        cloths();
    }
    public function cloths()
    {
        #if !openfl
        clothingInt = MapData.id(instance.clothing_set,";",",");
        #else
        var temp:Array<Int> = MapData.id(instance.clothing_set,";",",");
        if (!Static.arrayEqual(temp,clothingInt))
        {
            clothingInt = temp;
            trace("clothingInt " + clothingInt);
            var data = Main.data.objectMap.get(instance.po_id);
            var sprites:Array<Tile> = [];
            var clothsData:ObjectData;
            var offsetX:Float = 0;
            var offsetY:Float = 0;
            var index:Int = 0;
            var i:Int = 0;
            var place:Int = 0;
            for (id in clothingInt)
            {
                if (id > 0)
                {
                    switch (i++)
                    {
                        case 0: 
                        //hat (slight hack set hat to the front of hair)
                        index = data.headIndex;
                        place = 0 + 20;
                        case 1:
                        //tunic
                        index = data.bodyIndex;
                        place = 1;
                        case 2:
                        //front shoe
                        index = data.frontFootIndex;
                        place = 2;
                        case 3: 
                        //back shoe
                        index = data.backFootIndex;
                        place = 3;
                        case 4:
                        //bottom 
                        index = data.bodyIndex;
                        place = 4;
                        case 5:
                        //backpack
                        index = data.bodyIndex;
                        place = 5;
                    }
                    //clothing
                    clothsData = Main.data.objectMap.get(id);
                    offsetX = clothsData.clothingOffset.x + getTileAt(index).x;
                    offsetY = -clothsData.clothingOffset.y + getTileAt(index).y;
                    sprites = Main.objects.create(clothsData,offsetX,offsetY,true);
                    clothing.push(sprites);
                    for (sprite in sprites)
                    {
                        //addTile(sprite);
                        trace("index " + index + " plac " + place);
                        addTileAt(sprite,index + place + i);
                        //addTileAt(sprite,sprites.length - place);
                    }
                }else{
                    //sub
                }
            }
        }
        #end
    }
    #if openfl
    public function emote(index:Int=-1)
    {
        if (index == -1) return;
        var emot = Main.data.emotes[index];
        var data = Main.data.objectMap.get(instance.po_id);
        if (data == null || emot == null) return;
        //data.
    }
    #end
    public function hold()
    {
        #if !openfl
        if (Static.arrayEqual(instance.o_id,oid))
        {
            //change
            oid = instance.o_id;
        }
        #else
        if (!Static.arrayEqual(oid,instance.o_id))
        {
            //check if was player to re add to stage
            if (instance.o_id.length == 1 && instance.o_id[0] < 0) Main.objects.group.addTile(heldObject);
            //change
            oid = instance.o_id;
            removeTile(heldObject);
            if (oid.length == 0 || oid[0] == 0) return;
            //add
            if (oid[0] > 0)
            {
                heldObject = new TileContainer();
                Main.objects.add(oid,0,0,heldObject);
            }else{
                heldObject = Main.data.playerMap.get(oid[0] * -1);
                if (heldObject == null) 
                {
                    trace("held baby not found " + oid[0]);
                    return;
                }
                Main.objects.removeTile(heldObject);
            }
            addTile(heldObject);
            Actuate.stop(heldObject);
            Actuate.tween(heldObject,0.5,{x:instance.o_origin_x,y:-height/2 - instance.o_origin_y}).ease(Sine.easeInOut);
        }
        #end
    }
    #if openfl
    public function sprites():Array<Tile>
    {
        if (_sprites.length == 0)
        {
            for (i in 0...numTiles) _sprites.push(getTileAt(i));
            _sprites.remove(heldObject);
            for (array in clothing) for (cloths in array) _sprites.remove(cloths);
        }
        return _sprites;
    }
    public function age()
    {
        if (ageInt != Std.int(instance.age))
        {
            ageInt = Std.int(instance.age);
            Main.objects.visibleSprites(instance.po_id,sprites(),ageInt);
        }
    }
    #end
}