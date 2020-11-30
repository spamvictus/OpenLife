package openlife.data.transition;

import openlife.server.Server;
import openlife.data.object.ObjectData;
import haxe.io.Path;
import sys.io.File;
import openlife.engine.Engine;
@:expose
class TransitionImporter
{
    public var transitions:Array<TransitionData> = [];
    public var categories:Array<Category> = [];
    private var categoriesById:Map<Int, Category> = [];

    // transitions without any last use transitions
    private var transitionsByActorIdTargetId:Map<Int, Map<Int, TransitionData>>;
    // transitions where both actor and target is last use
    private var lastUseBothTransitionsByActorIdTargetId:Map<Int, Map<Int, TransitionData>>;
    // transitions where only actor is last use
    private var lastUseActorTransitionsByActorIdTargetId:Map<Int, Map<Int, TransitionData>>;
    // transitions where only target is last use
    private var lastUseTargetTransitionsByActorIdTargetId:Map<Int, Map<Int, TransitionData>>;

    public function new()
    {

    }

    public function importCategories()
    {
        categories = [];
        categoriesById = [];

        for (name in sys.FileSystem.readDirectory(Engine.dir + "categories"))
        {
            var category = new Category(File.getContent(Engine.dir + 'categories/$name'));
            
            categories.push(category);
            categoriesById[category.parentID] = category;

        }
    }

    public function importTransitions()
    {        
        if(categories.length == 0) importCategories();

        transitions = [];
        transitionsByActorIdTargetId = [];
        lastUseBothTransitionsByActorIdTargetId = [];
        lastUseActorTransitionsByActorIdTargetId = [];
        lastUseTargetTransitionsByActorIdTargetId = [];

        for (name in sys.FileSystem.readDirectory(Engine.dir + "transitions"))
        {
            
            var transition = TransitionData.createNewFromFile(Path.withoutExtension(name),File.getContent(Engine.dir + 'transitions/$name'));
            
            addTransition(transition);

            createAndaddCategoryTransitions(transition); 

        }

        trace('Transitions loaded: ${transitions.length}');
    }

    public function traceTransition(transition:TransitionData, s:String = "", targetDescContains:String = ""){

        var objectDataActor = Server.objectDataMap[transition.actorID];
        var objectDataTarget = Server.objectDataMap[transition.targetID];
        var objectDataNewActor = Server.objectDataMap[transition.newActorID];
        var objectDataNewTarget = Server.objectDataMap[transition.newTargetID];

        var actorDescription = "";
        var targetDescription = "";
        var newActorDescription = "";
        var newTargetDescription = "";

        if(objectDataActor != null) actorDescription = objectDataActor.description;
        if(objectDataTarget != null) targetDescription = objectDataTarget.description;
        if(objectDataNewActor != null) newActorDescription = objectDataNewActor.description;
        if(objectDataNewTarget != null) newTargetDescription = objectDataNewTarget.description;

        if(transition.targetID != 1206 && targetDescContains.length != 0 && targetDescription.indexOf(targetDescContains) == -1 ) return;
        
        //trace('$s $transition $actorDescription + $targetDescription  -->  $newActorDescription + $newTargetDescription\n');
    }

    private function getTransitionMap(lastUseActor:Bool, lastUseTarget:Bool):Map<Int, Map<Int, TransitionData>>
    {
        if(lastUseActor && lastUseTarget)
        {
            return lastUseBothTransitionsByActorIdTargetId;
        }
        else if(lastUseActor && lastUseTarget == false)
        {
            return lastUseActorTransitionsByActorIdTargetId;
        }
        else if(lastUseActor == false && lastUseTarget)
        {
            return lastUseTargetTransitionsByActorIdTargetId;
        } 
        else
        {
            return transitionsByActorIdTargetId;
        }
    }

    public function getTransition(actorId:Int, targetId:Int, lastUseActor:Bool = false, lastUseTarget:Bool = false):TransitionData{
        
        var transitionMap = getTransitionMap(lastUseActor, lastUseTarget);

        var transitionsByTargetId = transitionMap[actorId];

        if(transitionsByTargetId == null) return null;

        return transitionsByTargetId[targetId];
    }

    public function addTransition(transition:TransitionData,  lastUseActor:Bool = false, lastUseTarget:Bool = false){
        
        if(lastUseActor == false && lastUseTarget == false){
            // if transition is not a reverse transition, it can be done also on lastUse Items so add Transaction for that
            if(transition.lastUseActor == false && transition.reverseUseActor && transition.lastUseTarget == false && transition.reverseUseTarget) addTransition(transition, true, true);
            else if(transition.lastUseActor == false && transition.reverseUseActor) addTransition(transition, true, transition.lastUseTarget);
            else if(transition.lastUseTarget == false && transition.reverseUseTarget) addTransition(transition, transition.lastUseActor, true);
        }
        else{
            transition = transition.clone();
            if(lastUseActor) transition.lastUseActor = true;
            if(lastUseTarget) transition.lastUseTarget = true;
        }
       
        var transitionMap = getTransitionMap(transition.lastUseActor, transition.lastUseTarget);

        var transitionsByTargetId = transitionMap[transition.actorID];

        if(transitionsByTargetId == null){
            transitionsByTargetId = [];
            transitionMap[transition.actorID] = transitionsByTargetId;
        }

        var trans = transitionsByTargetId[transition.targetID];
        
        // TODO there are a lot of double transactions, like Oil Movement, Horse Stuff, Fence / Wall Alignment
        if(trans != null){
            traceTransition(trans, "WARNING DOUBLE 1!!", "Seed");
            traceTransition(transition, "WARNING DOUBLE 2!!", "Seed");
            return;
        }

        this.transitions.push(transition);
        transitionsByTargetId[transition.targetID] = transition;

        //traceTransition(transition, "", "Stone Pile");
        traceTransition(transition, "", "Seed");

        //if(transition.reverseUseTarget) traceTransition(transition, "", "");
    }

    // seems like obid can be at the same time a category and an object / Cabbage Seed + Bowl of Cabbage Seeds / 1206 + 1312
    // so better look also for @ in the description
    public function getCategory(id:Int) : Category
    {
        var objectData = Server.objectDataMap[id];

        if(objectData == null) return null;

        // TODO there was a reason for checking for @, but 1206 (Cabbage Seed) is an object and an category so wont work for this
        //if(objectData.description.indexOf("@") == -1) return null;

        return categoriesById[id];
    }

    public function createAndaddCategoryTransitions(transition:TransitionData){

        var actorCategory = getCategory(transition.actorID);
        var targetCategory = getCategory(transition.targetID);
        //var newTargetCategory = this.categoriesById[transition.newTargetID];
        var bothActionAndTargetIsCategory = (actorCategory != null) && (targetCategory != null);

        if(bothActionAndTargetIsCategory){
            //traceTransition(transition, 'bothActionAndTargetIsCategory: ');
            // TODO i dont know
            return;
        }

        // TODO 1600 is a pile, 1601 is a pile element: what to do with this transitions? 
        // @ Pile Element + @ Pile Element -->   + @ Pile 
        // 0   + @ Pile -->  @ Pile Element + @ Pile
        // Ignore piles for now
        if(actorCategory != null && (actorCategory.parentID == 1600 || actorCategory.parentID == 1601)) {
            trace(transition);
            return;
        }
        // if(newTargetCategory != null && newTargetCategory.parentID != 1600 && newTargetCategory.parentID != 1601) return;
        if(targetCategory != null && (targetCategory.parentID == 1600 || targetCategory.parentID == 1601)) {
            trace(transition);
            return;
        }

        var category = actorCategory;

        if(category != null){
            for(id in category.ids){                 
                if(targetCategory == null){
                    var newTransition = transition.clone();
                    newTransition.actorID = id;
                    if(newTransition.newActorID == category.parentID) newTransition.newActorID = id;

                    addTransition(newTransition);
                } 
                // TODO both category may not be needed
                else{
                    for(targetId in targetCategory.ids){

                        var newTransition = transition.clone();
                        newTransition.actorID = id;
                        newTransition.targetID = targetId;

                        if(newTransition.newActorID == category.parentID) newTransition.newActorID = id;
                        if(newTransition.newTargetID == targetCategory.parentID) newTransition.newTargetID = targetId;

                        addTransition(newTransition);
                        //traceTransition(newTransition, 'bothActionAndTargetIsCategory: ');

                    }
                }
            }
        }

        if(bothActionAndTargetIsCategory) return;

        // for transitions where actor is no category but target is a category
        category = targetCategory;

        if(category != null){
            for(id in category.ids){

                var newTransition = transition.clone();
                newTransition.targetID = id;
                if(newTransition.newTargetID == category.parentID) newTransition.newTargetID = id;

                addTransition(newTransition); 
            }
        }
    }
}