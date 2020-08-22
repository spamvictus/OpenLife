package openlife.data.transition;

import openlife.data.object.ObjectData;
import haxe.io.Path;
import sys.io.File;
import openlife.engine.Engine;
import sys.FileSystem;

class TransitionImporter
{
    var transitions:Array<TransitionData>;
    var categories:Array<Category>;
    public function new()
    {
        transitions = [];
        categories = [];
    }
    public function importCategories()
    {
        for (name in FileSystem.readDirectory(Engine.dir + "categories"))
        {
            var category = new Category(File.getContent(Engine.dir + 'categories/$name'));
            categories.push(category);
        }
    }
    public function importTransitions()
    {
        for (name in FileSystem.readDirectory(Engine.dir + "transitions"))
        {
            //Last use determines whether the current transition is used when numUses is greater than 1
            //MinUse for variable-use objects that occasionally use more than one "use", this sets a minimum per interaction.
            var transition = new TransitionData(Path.withoutExtension(name),File.getContent(Engine.dir + 'transitions/$name'));
            //actor + target = new actor + new target
            if (transition.actorID == 33)
            {
                Sys.println(new ObjectData(transition.actorID,true).description + " + " + new ObjectData(transition.targetID,true).description + " = " + 
                new ObjectData(transition.newActorID,true).description + " + " + new ObjectData(transition.newTargetID,true).description);
            }
            transitions.push(transition);
        }
    }
}