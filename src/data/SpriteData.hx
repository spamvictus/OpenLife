package data;
import openfl.geom.Point;

class SpriteData
{
    public var spriteID:Int=54;
    public var pos:Point = new Point();//=166.000000,107.000000
    public var rot:Float=0.000000;
    public var hFlip:Int=0;
    public var color:Array<Float> = [];//=0.952941,0.796078,0.756863
    public var ageRange:Array<Float> = [];//=-1.000000,-1.000000
    public var parent:Int = 0;//=-1
    //added
    public var inCenterXOffset:Int = 0;
    public var inCenterYOffset:Int = 0;
    public function new()
    {

    }
}