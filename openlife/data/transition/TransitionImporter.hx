package openlife.data.transition;

import openlife.data.object.ObjectData;
import haxe.io.Path;
import sys.io.File;
import openlife.engine.Engine;
@:expose
class TransitionImporter
{
    public var transitions:Array<TransitionData>;
    public var categories:Array<Category>;
    public function new()
    {

    }
    public function importCategories()
    {
        categories = [];
        for (name in sys.FileSystem.readDirectory(Engine.dir + "categories"))
        {
            var category = new Category(File.getContent(Engine.dir + 'categories/$name'));
            categories.push(category);
        }
    }
    public function importTransitions()
    {
        transitions = [];
        for (name in sys.FileSystem.readDirectory(Engine.dir + "transitions"))
        {
            //Last use determines whether the current transition is used when numUses is greater than 1
            //MinUse for variable-use objects that occasionally use more than one "use", this sets a minimum per interaction.
            var transition = new TransitionData(Path.withoutExtension(name),File.getContent(Engine.dir + 'transitions/$name'));
            //actor + target = new actor + new target
            transitions.push(transition);
        }
    }
}