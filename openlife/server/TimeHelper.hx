package openlife.server;

import haxe.Exception;
import hl.Type;
import openlife.auto.AiBase;
import openlife.auto.AiHelper;
import openlife.client.ClientTag;
import openlife.data.Point;
import openlife.data.object.ObjectData;
import openlife.data.object.ObjectHelper;
import openlife.data.transition.TransitionData;
import openlife.data.transition.TransitionImporter;
import openlife.macros.Macro;
import openlife.resources.ObjectBake;
import openlife.server.Biome.BiomeTag;
import openlife.server.GlobalPlayerInstance.Emote;
import openlife.server.Lineage.PrestigeClass;
import openlife.settings.ServerSettings;

@:enum abstract Seasons(Int) from Int to Int {
	public var Spring = 0;
	public var Summer = 1;
	public var Autumn = 2;
	public var Winter = 3;
}

class TimeHelper {
	public static var tickTime = 1 / 20;
	public static var tick:Float = 0; // some are skipped if server is too slow

	// public static var allTicks:Float = 0;   // these ticks will not be skipped, but can be slower then expected
	public static var lastTick:Float = 0;
	public static var serverStartingTime:Float;

	// Time Step Stuff
	private static var worldMapTimeStep = 0; // counts the time steps for doing map time stuff, since some ticks may be skiped because of server too slow
	private static var TimeTimeStepsSartedInTicks:Float = 0;
	private static var TimePassedToDoAllTimeSteps:Float = 0;
	private static var WinterDecayChance:Float = 0;
	private static var SpringRegrowChance:Float = 0;

	// Long Time Step Stuff
	private static var LongTimePassedToDoAllTimeSteps:Float = 0;
	private static var LongTimeTimeStepsSartedInTicks:Float = 0;

	// Seaons
	private static var TimeToNextSeasonInYears:Float = ServerSettings.SeasonDuration;
	private static var TimeSeasonStartedInTicks:Float = 0;
	private static var Season:Seasons = Seasons.Spring;
	private static var SeasonNames = ["Spring", "Summer", "Autumn", "Winter"];
	private static var SeasonTemperatureImpact:Float = 0;
	private static var SeasonHardness:Float = 1;
	public static var SeasonText:String = 'DONT KNOW';

	public static var ReadServerSettings:Bool = true;

	public static function CalculateTimeSinceTicksInSec(ticks:Float):Float {
		return (TimeHelper.tick - ticks) * TimeHelper.tickTime;
	}

	public static function DoTimeLoop() {
		serverStartingTime = Sys.time();
		var averageSleepTime:Float = 0.0;
		var skipedTicks = 0;
		var timeSinceStartCountedFromTicks:Float = TimeHelper.tick * TimeHelper.tickTime;
		serverStartingTime -= timeSinceStartCountedFromTicks; // pretend the server was started before to be aligned with ticks

		// trace('Server Startign time: sys.time: ${Sys.time()} serverStartingTime: $serverStartingTime timeSinceStartCountedFromTicks: $timeSinceStartCountedFromTicks');

		DoTest();

		// if(ServerSettings.NumberOfAis > 0) Ai.StartAiThread();
		AiBase.StartAiThread();

		while (true) {
			if (ServerSettings.UseOneGlobalMutex) WorldMap.world.mutex.acquire();

			TimeHelper.tick = Std.int(TimeHelper.tick + 1);

			var timeSinceStart:Float = Sys.time() - TimeHelper.serverStartingTime;
			timeSinceStartCountedFromTicks = TimeHelper.tick * TimeHelper.tickTime;

			// TODO what to do if server is too slow?
			if (TimeHelper.tick % 10 != 0 && timeSinceStartCountedFromTicks < timeSinceStart) {
				TimeHelper.tick = Std.int(TimeHelper.tick + 1);
				skipedTicks++;
			}
			if (TimeHelper.tick % 200 == 0) {
				averageSleepTime = Math.ceil(averageSleepTime / 200 * 1000) / 1000;
				trace('\nHum: ${Connection.getConnections().length} Time From Ticks: ${timeSinceStartCountedFromTicks} Time: ${Math.ceil(timeSinceStart)} Skiped Ticks: $skipedTicks Average Sleep Time: $averageSleepTime ');
				// trace('Connections: ${Connection.getConnections().length} Tick: ${TimeHelper.tick} Time From Ticks: ${timeSinceStartCountedFromTicks} Time: ${Math.ceil(timeSinceStart)} Skiped Ticks: $skipedTicks Average Sleep Time: $averageSleepTime ');
				averageSleepTime = 0;
				skipedTicks = 0;

				if(ReadServerSettings) ServerSettings.readFromFile(false);

				// if(Server.server.connections.length > 0) Server.server.connections[0].player.doDeath();
			}

			@:privateAccess haxe.MainLoop.tick();

			Macro.exception(TimeHelper.DoTimeStuff());

			timeSinceStart = Sys.time() - TimeHelper.serverStartingTime;

			if (ServerSettings.UseOneGlobalMutex) WorldMap.world.mutex.release();

			if (timeSinceStartCountedFromTicks > timeSinceStart) {
				var sleepTime = timeSinceStartCountedFromTicks - timeSinceStart;
				averageSleepTime += sleepTime;

				// trace('sleep: ${sleepTime}');
				Sys.sleep(sleepTime);
			}
		}
	}

	public static function DoTimeStuff() {
		var timePassedInSeconds = CalculateTimeSinceTicksInSec(lastTick);

		TimeHelper.lastTick = tick;

		DoSeason(timePassedInSeconds);

		GlobalPlayerInstance.AcquireMutex();

		for (c in Connection.getConnections()) {

			Macro.exception(DoTimeStuffForPlayer(c.player, timePassedInSeconds));

			var sendMoveEveryXTicks = ServerSettings.SendMoveEveryXTicks;

			if (sendMoveEveryXTicks > 0 && TimeHelper.tick % sendMoveEveryXTicks == 0) Macro.exception(c.sendToMeAllClosePlayers(false, false));
			if (TimeHelper.tick % 20 == 0) {
				// send still alive PU as workaround to unstuck stuck client
				//if(c.player.isMoving() == false) c.send(PLAYER_UPDATE, [c.player.toData()]);
				//c.send(PLAYER_UPDATE, [c.player.toData()]);
			}
		}

		for (ai in Connection.getAis()) {
			if(ai.player == null){
				Connection.removeAi(ai);
				continue;
			}
			Macro.exception(DoTimeStuffForPlayer(ai.player, timePassedInSeconds));
		}

		GlobalPlayerInstance.ReleaseMutex(); // TODO??? secure connections? since changing map stuff sends map updates to players

		Macro.exception(DoWorldMapTimeStuff()); // TODO currently it goes through the hole map each sec / this may later not work

		Macro.exception(RespawnObjects());

		Macro.exception(DoWorldLongTermTimeStuff());

		var worldMap = Server.server.map;

		// make sure they are not all at same tick!
		if ((tick + 20) % ServerSettings.TicksBetweenSaving == 0) Macro.exception(worldMap.updateObjectCounts());
		if (ServerSettings.saveToDisk
			&& tick % ServerSettings.TicksBetweenSaving == 0) Macro.exception(Server.server.map.writeToDisk(false));
		if (ServerSettings.saveToDisk
			&& (tick + 60) % ServerSettings.TicksBetweenBackups == Math.ceil(ServerSettings.TicksBetweenBackups / 2))
			Macro.exception(Server.server.map.writeBackup());

		DoTimeTestStuff();
	}

	private static function DoSeason(timePassedInSeconds:Float) {
		var passedSeasonTime = TimeHelper.CalculateTimeSinceTicksInSec(TimeSeasonStartedInTicks);
		var timeToNextSeasonInSec = TimeToNextSeasonInYears * 60;
		var tmpSeasonTemperatureImpact:Float = 0;

		tmpSeasonTemperatureImpact = ServerSettings.AverageSeasonTemperatureImpact * SeasonHardness;

		if (Season == Seasons.Spring || Season == Seasons.Autumn) tmpSeasonTemperatureImpact *= 0.25;
		if (Season == Seasons.Winter || Season == Seasons.Autumn) tmpSeasonTemperatureImpact *= -1;

		var factor = TimeToNextSeasonInYears * 15 * (1 / timePassedInSeconds);

		SeasonTemperatureImpact = (SeasonTemperatureImpact * factor + tmpSeasonTemperatureImpact) / (factor + 1);

		// if(tick % 20 == 0) trace('SEASON: ${SeasonHardness} TemperatureImpact: $SeasonTemperatureImpact tmp: $tmpSeasonTemperatureImpact');

		if (passedSeasonTime > timeToNextSeasonInSec) {
			var tmpSeasonHardness = SeasonHardness;

			TimeSeasonStartedInTicks = tick;
			TimeToNextSeasonInYears = ServerSettings.SeasonDuration / 2 + WorldMap.calculateRandomFloat() * ServerSettings.SeasonDuration;
			Season = (Season + 1) % 4;
			SeasonHardness = WorldMap.calculateRandomFloat() + 0.5;

			var seasonName = SeasonNames[Season];
			var message = 'SEASON: ${seasonName} is there! hardness: ${Math.round(SeasonHardness * 10) / 10} years: ${Math.round(passedSeasonTime / 60)} timeToNextSeasonInSec: $timeToNextSeasonInSec';

			trace(message);

			var hardSeason = (Season == Seasons.Winter || Season == Seasons.Summer) && SeasonHardness > 1.25;
			var hardText = hardSeason ? 'A hard ' : '';
			if (hardSeason && SeasonHardness > 1.4) {
				SeasonHardness += 0.1; // make it even harder
				hardText = 'A very hard ';
			}

			if (hardSeason) SeasonHardness = Math.pow(SeasonHardness, 2);

			// use same hardness for Spring as for winter. bad winter ==> good spring
			if (Season == Seasons.Spring) SeasonHardness = tmpSeasonHardness;

			TimeToNextSeasonInYears *= SeasonHardness;

			Connection.SendGlobalMessageToAll('$hardText ${seasonName} is comming!');

			TimeHelper.SeasonText = '$hardText ${seasonName}';
		}
	}

	private static function DoTimeStuffForPlayer(player:GlobalPlayerInstance, timePassedInSeconds:Float):Bool {
		if (player == null) return false;
		if (player.deleted) return false; // maybe remove?

		Macro.exception(player.connection.doTime(timePassedInSeconds));

		Macro.exception(UpdatePlayerStats(player, timePassedInSeconds));

		Macro.exception(updateAge(player, timePassedInSeconds));

		Macro.exception(updateFoodAndDoHealing(player, timePassedInSeconds));

		Macro.exception(MoveHelper.updateMovement(player));

		Macro.exception(DoTimeOnPlayerObjects(player, timePassedInSeconds));

		if (TimeHelper.tick % 20 == 0) Macro.exception(updateTemperature(player));

		if (TimeHelper.tick % 30 == 0) Macro.exception(UpdateEmotes(player));

		if (TimeHelper.tick % 50 == 0) Macro.exception(DisplayStuff(player));

		player.connection.send(FRAME, null, false, true);

		return true;
	}
	
	private static function DisplayStuff(player:GlobalPlayerInstance) {
		if (player.isHuman() == false) return;
		player.connection.sendMapChunkIfNeeded(); // to update seasonal biomes 
		if(player.account.displayClosePlayers) DisplayClosePlayers(player);
		if(player.age < 3) return;

		// display seasons
		var timeSinceLastHint = TimeHelper.CalculateTimeSinceTicksInSec(player.timeLastTemperatureHint);
		player.displaySeason = timeSinceLastHint > ServerSettings.DisplayTemperatureHintsPerMinute * 60;
		
		if(player.displaySeason && player.isSuperHot() && player.hits > 3){
			player.timeLastTemperatureHint = TimeHelper.tick;
			//if(player.isIll() == false){
				//if(Season == Seasons.Summer && ) player.say('too hot ${SeasonNames[Season]}', true);
				//player.say('too hot need cooling!', true);
			//}

			var season = Season == Seasons.Summer ? ' ${SeasonNames[Season]}' : ''; 
			var rand = WorldMap.calculateRandomInt(1);
		
			if(rand == 0) player.say('too hot${season} a river could help!', true);
			else if(rand == 1) player.say('too hot${season} some snow would be nice!', true);
			//else if(rand == 2) player.say('too hot${season} a jungle could help', true);			
			//else player.say('too hot${season} a desert would be warm!', true);
		}
		else if(player.displaySeason && player.isSuperCold() && player.hits > 3){
			player.timeLastTemperatureHint = TimeHelper.tick;
			//if(Season == Seasons.Winter) player.say('its ${SeasonNames[Season]} i need to get warmer', true);

			var season = Season == Seasons.Winter ? ' ${SeasonNames[Season]}' : ''; 
			var rand = WorldMap.calculateRandomInt(3);
		
			if(rand == 0) player.say('too cold${season} need a fire!', true);
			else if(rand == 1) player.say('too cold${season} need more clothing!', true);
			else if(rand == 2) player.say('too cold${season} a jungle could help', true);			
			else player.say('too cold${season} a desert would be warm!', true);
		} 
		
		//if(player.isSuperHot() || player.isSuperCold()) player.displaySeason = false;
		//else player.displaySeason = true;

		GlobalPlayerInstance.DisplayBestFood(player);

		if(player.hits > 1) AiHelper.DisplayCloseDeadlyAnimals(player, 10);	
	}

	private static function DisplayClosePlayers(player:GlobalPlayerInstance){
		if(ServerSettings.DisplayPlayerNamesDistance < 1) return;
		
		for(point in player.locationSaysPositions){
			player.connection.send(ClientTag.LOCATION_SAYS, ['${point.x} ${point.y} ']);
		}

		player.locationSaysPositions = new Array<Point>();

		var count = 0;
		var maxDistance = ServerSettings.DisplayPlayerNamesDistance * ServerSettings.DisplayPlayerNamesDistance;
		for(p in GlobalPlayerInstance.AllPlayers)
		{
			var quadDist = AiHelper.CalculateDistanceToPlayer(player, p);
			
			if(quadDist < 64) continue;
			if(quadDist > maxDistance) continue;
			
			var name = player.mother == p ? 'MOTHER' : p.name;
			if(player.partner == p) name = 'PARTNER';
			if(player.father == p) name = 'FATHER';
			var rx = WorldMap.world.transformX(player, p.tx);
			var ry = WorldMap.world.transformY(player, p.ty);
			var dist = Math.round(Math.sqrt(quadDist));
			if(ServerSettings.DisplayPlayerNamesShowDistance && dist > 9) name += '_${dist}M';

			//player.connection.send(PLAYER_UPDATE, [p.toRelativeData(player)], false);
			//player.connection.send(PLAYER_SAYS, ['${p.id}/$0 $name']);

			player.connection.send(ClientTag.LOCATION_SAYS, ['${rx} ${ry} ${name}']);
			player.locationSaysPositions.push(new Point(rx,ry));
			
			count++;
			if(count >= ServerSettings.DisplayPlayerNamesMaxPlayer) break;
		}
	}

	private static function UpdatePlayerStats(player:GlobalPlayerInstance, timePassedInSeconds:Float) {
		if (player.jumpedTiles > 0) player.jumpedTiles -= timePassedInSeconds * ServerSettings.MaxJumpsPerTenSec * 0.1;
		if (player.lastSayInSec > 0) player.lastSayInSec -= timePassedInSeconds;

		if(player.isBlocked(player.tx, player.ty)) MoveHelper.JumpToNonBlocked(player);

		if(player.connection.sock != null && player.connection.serverAi != null && ServerSettings.AutoFollowAi == false)
		{
			player.connection.serverAi = null;
			trace('WARNING ${player.name + player.id} has socket and serverAi! serverAi set null!');
		}

		if (player.heldPlayer != null && player.heldPlayer.deleted)
		{
			player.heldPlayer = null;
			player.o_id  = player.heldObject.toArray();
			trace('WARNING ${player.name + player.id} held player is dead! o_id set to: ${player.heldObject.name}');
		}
		if (player.heldByPlayer != null && player.heldByPlayer.deleted)
		{
			player.heldByPlayer = null;
			trace('WARNING ${player.name + player.id} heldByPlayer is dead!');
		}
		if (player.o_id[0] < 0 && player.heldPlayer == null)
		{
			player.o_id  = player.heldObject.toArray();
			trace('WARNING ${player.name + player.id} ${player.o_id[0]} < 0 but no player held! o_id set to: ${player.heldObject.name}');
		}
		
		// if(player.angryTime < 0 && player.angryTime > -1) player.angryTime = 0;

		// var moreAngry = player.isHoldingWeapon() || (player.lastPlayerAttackedMe != null && player.lastPlayerAttackedMe.isHoldingWeapon());
		var moreAngry = player.killMode || (player.lastPlayerAttackedMe != null && player.lastPlayerAttackedMe.isHoldingWeapon());

		if (moreAngry) {
			if (player.angryTime > -ServerSettings.CombatAngryTimeBeforeAttack) player.angryTime -= timePassedInSeconds;
		} else {
			if (player.angryTime < ServerSettings.CombatAngryTimeBeforeAttack) player.angryTime += timePassedInSeconds;
		}

		// if last attacker is far away set null
		if (player.lastPlayerAttackedMe != null) {
			var quadDist = AiHelper.CalculateDistanceToPlayer(player, player.lastPlayerAttackedMe);
			if (quadDist > 100) player.lastPlayerAttackedMe = null;
		}

		// add new follower
		if (player.newFollowerTime > 0) player.newFollowerTime -= timePassedInSeconds; else {
			if (player.newFollower != null) {
				var exileLeader = player.newFollower.isExiledByAnyLeader(player);
				var notExiled = exileLeader == null;

				if (notExiled && player.newFollower.followPlayer != player.newFollowerFor) {
					player.newFollower.followPlayer = player.newFollowerFor;
					Connection.SendFollowingToAll(player.newFollower);

					player.newFollower.connection.sendGlobalMessage('You follow now ${player.newFollowerFor.name} ${player.newFollowerFor.familyName}');

					// player.newFollower.say('now I follow ${player.newFollowerFor.name}');

					// player.say('He follows now ${player.newFollowerFor.name}');
				}

				player.newFollowerFor.newFollower = null;
				player.newFollowerFor.newFollowerFor = null;
				player.newFollower = null;
				player.newFollowerFor = null;
			}
		}

		if (player.hasYellowFever()) {
			var isHeldFaktor = player.heldByPlayer != null ? 0.2 : 1; // if taken care its much less hard!

			player.food_store -= timePassedInSeconds * ServerSettings.ExhaustionYellowFeverPerSec * 2;
			// player.exhaustion += timePassedInSeconds * ServerSettings.ExhaustionYellowFeverPerSec * isHeldFaktor;
			// player.hits += timePassedInSeconds * ServerSettings.ExhaustionYellowFeverPerSec * 0.05 * isHeldFaktor;

			player.heat += timePassedInSeconds * 0.02 * isHeldFaktor;
			if (player.heat > 1) player.heat = 1;

			player.food_store_max = player.calculateFoodStoreMax();

			if (TimeHelper.tick % 20 == 0) {
				player.sendFoodUpdate(false);
				player.connection.send(FRAME, null, false);
			}
		}
	}

	private static function DoTimeOnPlayerObjects(player:GlobalPlayerInstance, timePassedInSeconds:Float) {
		var obj = player.heldObject;

		// if(player.o_id[0] < 1) return;
		// if(obj.timeToChange <= 0) return;
		// obj.timeToChange -= timePassedInSeconds;

		if (obj.timeToChange > 0 && obj.isTimeToChangeReached()) {
			var transition = TransitionImporter.GetTransition(-1, obj.parentId, false, false);

			if (transition != null) {
				// var desc = obj.objectData.description;
				// use alternative outcome for example for wound on player vs on ground
				var alternativeTimeOutcome = obj.objectData.alternativeTimeOutcome;
				obj.id = alternativeTimeOutcome >= 0 ? alternativeTimeOutcome : transition.newTargetID;

				// trace('TIME: ${desc} --> ${obj.objectData.description} transition: ${transition.newTargetID} alternative: ${obj.objectData.alternativeTimeOutcome} passedTime: $passedTime neededTime: ${timeToChange}');

				obj.creationTimeInTicks = TimeHelper.tick;

				player.setHeldObject(obj);

				player.setHeldObjectOriginNotValid(); // no animation
			}
		}

		if (player.hiddenWound != null) {
			if (player.hiddenWound.isTimeToChangeReached()) {
				player.hiddenWound = null;
				player.doEmote(Emote.happy);
			} else {
				if (player.heldObject.id == 0) {
					player.setHeldObject(player.hiddenWound);
					player.setHeldObjectOriginNotValid(); // no animation
					Connection.SendUpdateToAllClosePlayers(player, false);
				}
			}

			if (player.hiddenWound != null && player.hiddenWound.id == 0) player.hiddenWound = null;
		}

		if (player.fever != null) {
			if (player.fever.isTimeToChangeReached()) {
				player.fever = null;
				player.doEmote(Emote.happy);
				player.connection.sendGlobalMessage('You survived yellow fever! Next time you will be more resistant...');
			}
		}

		// TODO contained objects
		// TODO clothing decay / contained objects --> like in backpack
	}

	private static function UpdateEmotes(player:GlobalPlayerInstance) {
		
		if (player.isWounded()) {
			Connection.SendEmoteToAll(player, Emote.shock);
			return;
		}

		// if(player.isHoldingWeapon() && player.angryTime < ServerSettings.CombatAngryTimeBeforeAttack / 2 )
		if (player.angryTime < 2) {
			if (player.isHoldingWeapon()) player.doEmote(Emote.murderFace); else {
				var lastPlayerAttackedMe = player.lastPlayerAttackedMe;
				if (lastPlayerAttackedMe != null
					&& lastPlayerAttackedMe.lastAttackedPlayer == player
					&& lastPlayerAttackedMe.isHoldingWeapon()) player.doEmote(Emote.terrified); else
					player.doEmote(Emote.angry);
			}

			return;
		}

		if (player.hasYellowFever()) {
			if (player.isSuperHot()) player.doEmote(Emote.heatStroke); else
				player.doEmote(Emote.yellowFever);
			return;
		}

		if (player.food_store < 0 && player.age >= ServerSettings.MinAgeToEat) {
			player.doEmote(Emote.starving);
			return;
		}

		if (player.angryTime < ServerSettings.CombatAngryTimeBeforeAttack) {
			if (player.isHoldingWeapon()) player.doEmote(Emote.angry); else {
				if (player.lastPlayerAttackedMe != null && player.lastPlayerAttackedMe.isHoldingWeapon()) player.doEmote(Emote.shock); else
					player.doEmote(Emote.angry);
			}
		}

		if (player.isSuperHot()) player.doEmote(Emote.heatStroke);
		if (player.isSuperCold()) player.doEmote(Emote.pneumonia);
		// else if(playerHeat > 0.6) player.doEmote(Emote.dehydration);

		if (player.isHoldingChildInBreastFeedingAgeAndCanFeed()) {
			player.heldPlayer.doEmote(Emote.happy);
		}

		if (player.mother != null) {
			// if(this.isAi() == false) this.connection.sendMapLocation(this.mother,'MOTHER', 'mother');
			// if(player.isAi() == false) player.connection.sendMapLocation(player.mother,'MOTHER', 'leader');
			// if(player.mother.isAi() == false) player.mother.connection.sendMapLocation(player,'BABY', 'baby');
		}
	}

	private static function updateAge(player:GlobalPlayerInstance, timePassedInSeconds:Float) {
		var tmpAge = player.age;
		var healthFactor = player.CalculateHealthAgeFactor();
		var ageingFactor:Float = 1;	

		// trace('aging: ${aging}');
		// trace('player.age_r: ${player.age_r}');
		// trace('healthFactor: ${healthFactor}');

		if (player.age < ServerSettings.GrownUpAge) {
			//ageingFactor = healthFactor;
		} else {
			ageingFactor = 1 / healthFactor;
		}

		if(player.isHuman() && player.mother != null && player.mother.isAi() && player.age < ServerSettings.MinAgeToEat){
			ageingFactor *= ServerSettings.AgingFactorHumanBornToAi;
			//if(TimeHelper.tick % 20 == 0) trace('ageing: human born to ai: $ageingFactor'); 
		}
		else if(player.isAi() && player.mother != null && player.mother.isHuman() && player.age < ServerSettings.MinAgeToEat){
			ageingFactor *= ServerSettings.AgingFactorAiBornToHuman;
			//if(TimeHelper.tick % 20 == 0) trace('ageing: human born to ai: $ageingFactor'); 
		}

		if (player.food_store < 0) {
			if (player.age < ServerSettings.GrownUpAge) {
				ageingFactor *= ServerSettings.AgingFactorWhileStarvingToDeath;
			} else {
				ageingFactor *= 1 / ServerSettings.AgingFactorWhileStarvingToDeath;
			}
		}

		player.age_r = ServerSettings.AgeingSecondsPerYear / ageingFactor;
		var ageing = timePassedInSeconds / ServerSettings.AgeingSecondsPerYear;

		player.trueAge += ageing;

		ageing *= ageingFactor;

		player.age += ageing;

		// trace('player.age: ${player.age}');

		if (Std.int(tmpAge) != Std.int(player.age)) {
			if (ServerSettings.DebugPlayer)
				trace('Player: ${player.p_id} Old Age: $tmpAge New Age: ${player.age} TrueAge: ${player.trueAge} agingFactor: $ageingFactor healthFactor: $healthFactor');

			// player.yum_multiplier -= ServerSettings.MinHealthPerYear; // each year some health is lost
			player.food_store_max = player.calculateFoodStoreMax();

			// decay some coins per year
			if (Std.int(player.trueAge) % 10 == 0 && player.coins > 10) {
				var decayedCoins:Float = Std.int(player.coins / 10); // 1% per year
				var maxPrestigeFromCoins = player.prestige / 5;
				player.coins -= decayedCoins;

				maxPrestigeFromCoins = Math.max(maxPrestigeFromCoins, ServerSettings.MinPrestiegeFromCoinDecayPerYear * 10);
				decayedCoins = Math.min(decayedCoins, maxPrestigeFromCoins);
				player.addPrestige(decayedCoins);
				player.prestigeFromWealth += decayedCoins;
			}

			if (player.age > 60) player.doDeath('reason_age');

			// trace('update age: ${player.age} food_store_max: ${player.food_store_max}');
			player.sendFoodUpdate(false);

			//if (player.isMoving() == false) Connection.SendUpdateToAllClosePlayers(player, false);

			if (Std.int(player.trueAge) % 10 == 0){ 
				var coins:Float = Std.int(player.coins);
				var text = coins >= 10 ? 'You have ${coins} coins! You can use: I give you IXC' : '';
				player.connection.sendGlobalMessage(text);
			}

			if (Std.int(player.age) == 58) {
				trace('Player: ${player.name + player.p_id} death is near!');

				var factor = ServerSettings.DisplayScoreFactor;
				var totalPrestige = Math.floor(player.yum_multiplier);
				var prestigeFromChildren = Math.floor(player.prestigeFromChildren);
				var prestigeFromFollowers = Math.floor(player.prestigeFromFollowers);
				var prestigeFromEating = Math.floor(player.prestigeFromEating);
				var prestigeFromParents = Math.floor(player.prestigeFromParents);
				var prestigeFromSiblings = Math.floor(player.prestigeFromSiblings);
				
				var textFromChildren = prestigeFromChildren > 5 ? 'You have gained in total ${prestigeFromChildren * factor} prestige from children!' : '';
				var textFromFollowers = prestigeFromFollowers > 5 ? 'You have gained in total ${prestigeFromFollowers * factor} prestige from followers!' : '';
				var textFromEating = prestigeFromEating > 5 ? 'You have gained in total ${prestigeFromEating * factor} prestige from YUMMY food!' : '';
				var textFromWealth = player.prestigeFromWealth > 5 ? 'You have gained ${player.prestigeFromWealth * factor} prestige from your wealth!' : '';
				var textFromParents = prestigeFromParents > 5 ? 'You have gained ${prestigeFromParents * factor} prestige from parents!' : '';
				var textFromSiblings = prestigeFromSiblings > 5 ? 'You have gained ${prestigeFromSiblings * factor} prestige from siblings!' : '';

				// trace('New Age: $message');
				player.connection.sendGlobalMessage('Your life nears the end. You earned ${totalPrestige}!');

				if(ServerSettings.DisplayScoreOn){
					player.connection.sendGlobalMessage(textFromChildren);
					player.connection.sendGlobalMessage(textFromFollowers);
					player.connection.sendGlobalMessage(textFromEating);
					player.connection.sendGlobalMessage(textFromWealth);
					player.connection.sendGlobalMessage(textFromParents);
					player.connection.sendGlobalMessage(textFromSiblings);		
				}
			}

			ScoreEntry.ProcessScoreEntry(player);
		}
	}

	private static function updateFoodAndDoHealing(player:GlobalPlayerInstance, timePassedInSeconds:Float) {
		// trace('food_store: ${connection.player.food_store}');

		var tmpFood = Math.ceil(player.food_store);
		var tmpExtraFood = Math.ceil(player.yum_bonus);
		var tmpFoodStoreMax = Math.ceil(player.food_store_max);
		var originalFoodDecay = timePassedInSeconds * player.foodUsePerSecond; // depends on temperature
		var playerIsStarvingOrHasBadHeat = player.food_store < 0 || player.isSuperCold() || player.isSuperHot();
		var doHealing = playerIsStarvingOrHasBadHeat == false && player.isWounded() == false && player.hasYellowFever() == false;
		var foodDecay = originalFoodDecay;
		var healing = timePassedInSeconds * ServerSettings.HealingPerSecond;
		//var healing = 1.5 * timePassedInSeconds * ServerSettings.FoodUsePerSecond - originalFoodDecay;

		// healing is between 0.5 and 2 of food decay depending on temperature
		if (healing < timePassedInSeconds * ServerSettings.FoodUsePerSecond / 2) healing = timePassedInSeconds * ServerSettings.FoodUsePerSecond / 2;
		// if(tick % 20 == 0) trace('${player.id} heat: ${player.heat} faktor: ${healing / originalFoodDecay} healing: $healing foodDecay: $originalFoodDecay');

		if (player.age < ServerSettings.GrownUpAge && player.food_store > 0) foodDecay *= ServerSettings.FoodUseChildFaktor;

		if(player.isAi()){
			if(player.lineage.prestigeClass == PrestigeClass.Serf) foodDecay *= ServerSettings.AIFoodUseFactorSerf;
			else if(player.lineage.prestigeClass == PrestigeClass.Commoner) foodDecay *= ServerSettings.AIFoodUseFactorCommoner;
			else if(player.lineage.prestigeClass == PrestigeClass.Noble) foodDecay *= ServerSettings.AIFoodUseFactorNoble;
		}

		// do damage if wound
		if (player.isWounded() || player.hiddenWound != null) {
			var wound = player.isWounded() ? player.heldObject : player.hiddenWound;
			var bleedingDamage = timePassedInSeconds * wound.objectData.damage * ServerSettings.WoundDamageFactor;
			player.hits += bleedingDamage;
			foodDecay += 2 * bleedingDamage;
			// player.exhaustion += bleedingDamage;
		}

		// do damage while starving
		if (player.food_store < 0) {
			player.hits += originalFoodDecay * 0.5;
		}

		// take care of exhaustion
		var exhaustionFoodNeed = 0.0;
		// if(healing > 0 && player.exhaustion > -player.food_store_max && player.food_store > 0)
		if (doHealing && player.exhaustion > -player.food_store_max) {
			var healingFaktor = player.isMale() ? ServerSettings.ExhaustionHealingForMaleFaktor : 1;
			//var exhaustionFaktor = player.exhaustion > player.food_store_max / 2 ? 2 : 1;
			var exhaustionFaktor:Float = 1;
			exhaustionFoodNeed = originalFoodDecay * ServerSettings.ExhaustionHealingFactor * exhaustionFaktor;

			player.exhaustion -= healing * ServerSettings.ExhaustionHealingFactor * healingFaktor * exhaustionFaktor;
			foodDecay += exhaustionFoodNeed;
		}

		// take damage if temperature is too hot or cold
		var damage:Float = 0;
		if (player.isSuperHot()) damage = player.heat > 0.95 ? 2 * originalFoodDecay : originalFoodDecay;
		else if (player.isSuperCold())
			damage = player.heat < 0.05 ? 2 * originalFoodDecay : originalFoodDecay;

		damage *= 0.5 * ServerSettings.DamageTemperatureFactor;
		player.hits += damage;
		player.exhaustion += damage;

		// do Biome exhaustion
		// var tmpexhaustion = player.exhaustion;
		var biomeLoveFactor = player.biomeLoveFactor();
		if(biomeLoveFactor > 1) biomeLoveFactor = 1;
		// if(biomeLoveFactor < 0) player.exhaustion -= originalFoodDecay * biomeLoveFactor / 2; // gain exhaustion in wrong biome
		if (biomeLoveFactor > 0
			&& player.exhaustion > -player.food_store_max) player.exhaustion -= healing * 0.5 * biomeLoveFactor;
		// trace('Exhaustion: $tmpexhaustion ==> ${player.exhaustion} pID: ${player.p_id} biomeLoveFactor: $biomeLoveFactor');

		// do healing but increase food use
		//if (player.hits > 0) {
		if(healing > 0 && player.hits > 0 && playerIsStarvingOrHasBadHeat == false && player.isWounded() == false){
			//var healingFaktor = doHealing ? 1.0 : 0.0;
			//var foodDecayFaktor = doHealing ? 2 : 1;

			player.hits -= healing * ServerSettings.WoundHealingFactor; // * healingFaktor;

			foodDecay += originalFoodDecay * ServerSettings.WoundHealingFactor; // * foodDecayFaktor;

			if (player.hits < 0) player.hits = 0;

			if (player.woundedBy != 0 && player.hits < 1) {
				player.woundedBy = 0;
				if (player.connection != null) player.connection.send(ClientTag.HEALED, ['${player.p_id}']);
			}
		}

		// if starving to death and there is some health left, reduce food need and health
		if (player.food_store < 0 && player.yum_multiplier > 0) {
			player.yum_multiplier -= foodDecay;
			foodDecay /= 2;
		}

		// do breast feeding
		var heldPlayer = player.heldPlayer;

		if (player.isHoldingChildInBreastFeedingAgeAndCanFeed()) {
			// trace('feeding:');

			if (heldPlayer.food_store < heldPlayer.getMaxChildFeeding()) {
				var food = ServerSettings.FoodRestoreFactorWhileFeeding * timePassedInSeconds * ServerSettings.FoodUsePerSecond;
				var tmpFood = Math.ceil(heldPlayer.food_store);

				heldPlayer.food_store += food;
				foodDecay += food / 2;

				//if (heldPlayer.hits > 0) heldPlayer.hits -= timePassedInSeconds * 0.2;

				var hasChanged = tmpFood != Math.ceil(heldPlayer.food_store);
				if (hasChanged) {
					heldPlayer.sendFoodUpdate(false);
					heldPlayer.connection.send(FRAME, null, false);
				}

				// trace('feeding: $food foodDecay: $foodDecay');
			}

			if (heldPlayer.hits > 0){
				heldPlayer.hits -= timePassedInSeconds * 0.2;
			}
		}

		foodDecay *= player.isEveOrAdam() && player.isWounded() == false ? ServerSettings.EveFoodUseFactor : 1;

		if (player.yum_bonus > 0) {
			player.yum_bonus -= foodDecay;
		} else {
			player.food_store -= foodDecay;
		}

		//if (TimeHelper.tick % 40 == 0) trace('${player.name + player.id} FoodDecay: ${Math.round(foodDecay / timePassedInSeconds * 100) / 100} org: ${Math.round(originalFoodDecay / timePassedInSeconds * 100) / 100)} fromexh: ${Math.round(exhaustionFoodNeed / timePassedInSeconds * 100) / 100}');
		if (ServerSettings.DebugPlayer && TimeHelper.tick % 40 == 0) trace('${player.name + player.id} FoodDecay: ${Math.round(foodDecay / timePassedInSeconds * 100) / 100} org: ${Math.round(originalFoodDecay / timePassedInSeconds * 100) / 100)} fromexh: ${Math.round(exhaustionFoodNeed / timePassedInSeconds * 100) / 100}');

		player.food_store_max = player.calculateFoodStoreMax();

		var hasChanged = tmpFood != Math.ceil(player.food_store) || tmpExtraFood != Math.ceil(player.yum_bonus);
		hasChanged = hasChanged || tmpFoodStoreMax != Math.ceil(player.food_store_max);

		if (hasChanged) {
			player.sendFoodUpdate(false);
			player.connection.send(FRAME, null, false);
		}

		if (player.food_store_max < ServerSettings.DeathWithFoodStoreMax) {
			var reason = player.woundedBy == 0 ? 'reason_hunger' : 'reason_killed_${player.woundedBy}';

			player.doDeath(reason);

			Connection.SendUpdateToAllClosePlayers(player, false);
		}
	}

	/*
		HX
		heat food_time indoor_bonus#

		Tells player about their current heat value, food drain time, and indoor bonus.

		Food drain time and indoor bonus are in seconds.

		Food drain time is total including bonus.
	 */
	// Heat is the player's warmth between 0 and 1, where 0 is coldest, 1 is hottest, and 0.5 is ideal.
	private static function updateTemperature(player:GlobalPlayerInstance) {
		
		var timePassed = TimeHelper.CalculateTimeSinceTicksInSec(player.timeLastTemperatureCalculation);
		
		if(timePassed > 5) timePassed = 5;

		player.timeLastTemperatureCalculation = TimeHelper.tick;

		var temperature = calculateTemperature(player, player.tx, player.ty);	
		
		var closestHeatObj = AiHelper.GetClosestHeatObject(player);

		// TODO move inside calculateTemperature so that it is considered for olf cold / hot place
		if (closestHeatObj != null) {
			var heatObjectFactor = ServerSettings.TemperatureHeatObjectFactor;
			var quadDistance = 10 + AiHelper.CalculateQuadDistanceToObject(player, closestHeatObj);
			var closestHeatTemperature = closestHeatObj.objectData.heatValue / (heatObjectFactor * quadDistance);
			
			closestHeatTemperature *= ServerSettings.TemperatureHeatObjFactor;
			temperature += closestHeatTemperature;

			// use only half impact of close heat object if negative
			if (player.heat < 0.5 && closestHeatTemperature < 0) {
				temperature -= closestHeatTemperature / 2;
				//if (temperature > 0.5) temperature = 0.5;
			}
			if (player.heat > 0.5 && closestHeatTemperature > 0) {
				temperature -= closestHeatTemperature / 2;
				//if (temperature < 0.5) temperature = 0.5;
			}

			//trace('${closestHeatObj.description} Heat: ${closestHeatObj.objectData.heatValue} value: $closestHeatTemperature distance: $distance');
		}

		// set cold / hot place
		if(temperature > 0.55){
			if(player.warmPlace == null){
				player.warmPlace = new ObjectHelper(null, 0);
				player.warmPlace.tx = player.tx;
				player.warmPlace.ty = player.ty;
			}
			else{
				var warmPlace = player.warmPlace;
				var quadDist = AiHelper.CalculateDistance(player.tx, player.ty, warmPlace.tx, warmPlace.ty);
				var warmPlaceTemperature = calculateTemperature(player, warmPlace.tx, warmPlace.ty);	
				var oldfitness = (warmPlaceTemperature - 0.5)  / (quadDist + 100);
				var newfitness = (temperature - 0.5) / 100;
				if(newfitness >= oldfitness){
					warmPlace.tx = player.tx;
					warmPlace.ty = player.ty;
				}
				//trace('heat: found warm Place');
			}
		}
		if(temperature < 0.45){
			if(player.coldPlace == null){
				player.coldPlace = new ObjectHelper(null, 0);
				player.coldPlace.tx = player.tx;
				player.coldPlace.ty = player.ty;
			}
			else{
				var coldPlace = player.coldPlace;
				var quadDist = AiHelper.CalculateDistance(player.tx, player.ty, coldPlace.tx, coldPlace.ty);
				var coldPlaceTemperature = calculateTemperature(player, coldPlace.tx, coldPlace.ty);	
				var oldfitness = (0.5 - coldPlaceTemperature)  / (quadDist + 100);
				var newfitness = (0.5 - temperature) / 100;
				if(newfitness >= oldfitness){
					coldPlace.tx = player.tx;
					coldPlace.ty = player.ty;
				}

				//trace('heat: found cold Place');
			}
		}

		// apply clothing temp
		var clothingInsulation = player.calculateClothingInsulation(); // clothing insulation can be between 0 and 2 for now

		var clothingHeatProtection = player.calculateClothingHeatProtection(); // (1-Insulation) clothing heat protection can be between 0 and 2 for now

		temperature += clothingInsulation / 10;

		// if(temperature > 0.5) temperature -= (temperature - 0.5) * clothingHeatProtection; // the hotter the better the heat protection

		if (temperature > 0.5) {
			temperature -= clothingHeatProtection / 10;
			if (temperature < 0.5) temperature = 0.5;
		}

		// if(temperature < 0) temperature = 0;
		// if(temperature > 1) temperature = 1;

		var insulationFactor =  1 / (1 + clothingInsulation * ServerSettings.TemperatureClothingInsulationFactor); 

		var naturalHeatInsulation = ServerSettings.TemperatureNaturalHeatInsulation - clothingInsulation;

		if(naturalHeatInsulation < 0) naturalHeatInsulation = 0;

		clothingHeatProtection += naturalHeatInsulation;

		var heatProtectionFactor =  1 / (1 + clothingHeatProtection * ServerSettings.TemperatureClothingInsulationFactor); 

		var clothingFactor = temperature < 0.5 ? insulationFactor : heatProtectionFactor;

		//if (player.heat < 0.5 && player.heat < temperature) clothingFactor -= 0.1; // heating is positiv, so allow it more
		//else if (player.heat > 0.5 && player.heat > temperature) clothingFactor -= 0.1; // cooling is positiv, so allow it more	

		// consider held object heat
		var heldObjectData = player.heldObject.objectData;
		if (heldObjectData.heatValue != 0) temperature += (heldObjectData.heatValue / 20) * ServerSettings.TemperatureHeatObjFactor;

		// add SeasonTemperatureImpact
		var seasonImpact = SeasonTemperatureImpact;
		if(seasonImpact > 0) seasonImpact *= ServerSettings.HotSeasonTemperatureFactor;
		if(seasonImpact < 0) seasonImpact *= ServerSettings.ColdSeasonTemperatureFactor;
		temperature += seasonImpact;

		// balance temperature out if the biome is loved
		var biomeLoveFactor = player.biomeLoveFactor();
		var biomeLoveTemperatureBoni = biomeLoveFactor / 10;
		var maxLovedBiomeImpact = ServerSettings.TemperatureMaxLovedBiomeImpact;
		biomeLoveTemperatureBoni *= ServerSettings.TemperatureLovedBiomeFactor;
		if(biomeLoveTemperatureBoni > maxLovedBiomeImpact) biomeLoveTemperatureBoni = maxLovedBiomeImpact;

		if (biomeLoveTemperatureBoni > 0) {
			//trace('${player.p_id} biomeLoveFactor: $biomeLoveFactor temperatureboni: $biomeLoveTemperatureBoni');

			if (player.heat < 0.5 && temperature < 0.5) {
				temperature += biomeLoveTemperatureBoni;
				//if (temperature > 0.5) temperature = 0.5;
			}
			if (player.heat > 0.5 && temperature > 0.5) {
				temperature -= biomeLoveTemperatureBoni;
				//if (temperature < 0.5) temperature = 0.5;
			}
		}

		// If hold by other player, just use temperature from this instead
		if (player.heldByPlayer != null) temperature = player.heldByPlayer.heat;

		var biomeId =  WorldMap.world.getBiomeId(player.tx, player.ty);
		var isInWater = biomeId == PASSABLERIVER || biomeId == OCEAN;
		var waterFactor = isInWater ? ServerSettings.TemperatureInWaterFactor : 1;
		var newTemperatureIsPositive = (player.heat > 0.5 && temperature < 0.5) || (player.heat < 0.5 && temperature > 0.5);
		var temperatureImpactPerSec = ServerSettings.TemperatureImpactPerSec;		
		var timeFactor = newTemperatureIsPositive ? ServerSettings.TemperatureImpactPerSecIfGood : temperatureImpactPerSec;
		var impactReduction = ServerSettings.TemperatureImpactReduction; 
		var heatchange =  temperature - (0.5 * impactReduction + player.heat * (1 - impactReduction)); 
		// ignore clothing if heat change is positive or if in water
		player.heat += newTemperatureIsPositive || isInWater ? waterFactor * timeFactor * timePassed * heatchange: clothingFactor * timeFactor * timePassed * heatchange;

		if (player.heat > 1) player.heat = 1;
		if (player.heat < 0) player.heat = 0;

		var playerHeat = player.heat;
		var temperatureFoodFactor = playerHeat >= 0.5 ? playerHeat : 1 - playerHeat;
		
		// also consider the food needed for the temperature damage
		var temperatureDamageFactor:Float = 0;
		if (player.isSuperHot())
			temperatureDamageFactor = player.heat > 0.95 ? 2 : 1;
		else if (player.isSuperCold())
			temperatureDamageFactor = player.heat < 0.05 ? 2 : 1;

		temperatureDamageFactor = 1 + temperatureDamageFactor * ServerSettings.DamageTemperatureFactor;

		var foodUsePerSecond = ServerSettings.FoodUsePerSecond * temperatureFoodFactor;
		var foodDrainTime = 1 / (foodUsePerSecond * temperatureDamageFactor);
		//trace('foodDrainTime: ${foodDrainTime} temperatureDamageFactor: $temperatureDamageFactor');

		player.foodUsePerSecond = foodUsePerSecond;
		temperature = Math.round(temperature * 100) / 100;
		player.lastTemperature = temperature;
		foodDrainTime = Math.round(foodDrainTime * 100) / 100;

		var message = '$playerHeat $foodDrainTime 0';

		player.connection.send(HEAT_CHANGE, [message], false);

		if(ServerSettings.DebugTemperature) player.say('H ${Math.round(playerHeat * 100) / 100}} T $temperature'); 			
		if(ServerSettings.DebugTemperature)
		  trace('${player.name + player.id} Temperature: $temperature playerHeat: ${Math.round(playerHeat * 100) / 100} clothingFactor: $clothingFactor foodDrainTime: $foodDrainTime foodUsePerSecond: $foodUsePerSecond clothingInsulation: $clothingInsulation clothingHeatProtection: $clothingHeatProtection');
	}

	// Heat is the player's warmth between 0 and 1, where 0 is coldest, 1 is hottest, and 0.5 is ideal.
	private static function calculateTemperature(player:GlobalPlayerInstance, tx:Int, ty:Int):Float {
		var maxBiomeDistance = 10;
		var biome = WorldMap.worldGetBiomeId(tx, ty);
		var originalBiomeTemperature = Biome.getBiomeTemperature(biome);
		var biomeTemperature = originalBiomeTemperature;

		// looke for close biomes that influence temperature
		if (biome == BiomeTag.GREEN || biome == BiomeTag.YELLOW || biome == BiomeTag.GREY) {
			// direct x / y
			for (ii in 1...maxBiomeDistance - 1) {
				biomeTemperature = CalculateTemperatureAtPosition(tx + ii, ty, "+X", ii, maxBiomeDistance, biomeTemperature);
				if (biomeTemperature != originalBiomeTemperature) break;
			}

			for (ii in 1...maxBiomeDistance - 1) {
				biomeTemperature = CalculateTemperatureAtPosition(tx - ii, ty, "-X", ii, maxBiomeDistance, biomeTemperature);
				if (biomeTemperature != originalBiomeTemperature) break;
			}

			for (ii in 1...maxBiomeDistance - 1) {
				biomeTemperature = CalculateTemperatureAtPosition(tx, ty + ii, "+Y", ii, maxBiomeDistance, biomeTemperature);
				if (biomeTemperature != originalBiomeTemperature) break;
			}

			for (ii in 1...maxBiomeDistance - 1) {
				biomeTemperature = CalculateTemperatureAtPosition(tx, ty - ii, "-Y", ii, maxBiomeDistance, biomeTemperature);
				if (biomeTemperature != originalBiomeTemperature) break;
			}

			// diagonal x / y
			for (ii in 1...maxBiomeDistance - 1) {
				biomeTemperature = CalculateTemperatureAtPosition(tx + ii, ty + ii, "+X+Y", ii, maxBiomeDistance, biomeTemperature);
				if (biomeTemperature != originalBiomeTemperature) break;
			}

			for (ii in 1...maxBiomeDistance - 1) {
				biomeTemperature = CalculateTemperatureAtPosition(tx - ii, ty - ii, "-X-Y", ii, maxBiomeDistance, biomeTemperature);
				if (biomeTemperature != originalBiomeTemperature) break;
			}

			for (ii in 1...maxBiomeDistance - 1) {
				biomeTemperature = CalculateTemperatureAtPosition(tx - ii, ty + ii, "-X+Y", ii, maxBiomeDistance, biomeTemperature);
				if (biomeTemperature != originalBiomeTemperature) break;
			}

			for (ii in 1...maxBiomeDistance - 1) {
				biomeTemperature = CalculateTemperatureAtPosition(tx + ii, ty - ii, "+X-Y", ii, maxBiomeDistance, biomeTemperature);
				if (biomeTemperature != originalBiomeTemperature) break;
			}
		}

		var colorTemperatureShift = getIdealTemperatureShiftForColor(player.getColor());

		// between -0.2 (black in snow) to 1.1 Ginger in dessert
		var temperature = biomeTemperature - colorTemperatureShift;

		if (ServerSettings.DebugTemperature)
			trace('${player.name}${player.id} calculateTemperature: temperature: $temperature biomeTemperature: $biomeTemperature colorTemperatureShift: $colorTemperatureShift');

		return temperature;
	}

	private static function getIdealTemperatureShiftForColor(personColor:PersonColor):Float {
		if (personColor == PersonColor.Black) return ServerSettings.TemperatureShiftForBlack;
		if (personColor == PersonColor.Brown) return ServerSettings.TemperatureShiftForBrown;
		if (personColor == PersonColor.White) return ServerSettings.TemperatureShiftForWhite;
		if (personColor == PersonColor.Ginger) return ServerSettings.TemperatureShiftForGinger;

		return 0;
	}

	private static function CalculateTemperatureAtPosition(tx:Int, ty:Int, debugString:String, distance:Int, maxBiomeDistance:Int,
			originalTemperature:Float):Float {
		var biome = WorldMap.worldGetBiomeId(tx, ty);
		var biomeTemperature = originalTemperature;

		if (biome == BiomeTag.DESERT || biome == BiomeTag.JUNGLE || biome == BiomeTag.SNOW) {
			var tmpBiomeTemperature = Biome.getBiomeTemperature(biome);
			biomeTemperature = (originalTemperature * distance + tmpBiomeTemperature * (maxBiomeDistance - distance)) / maxBiomeDistance;

			if (ServerSettings.DebugTemperature)
				trace('TEST BiomeTemp: $debugString distance: $distance biomeTemperature: $biomeTemperature tmpBiomeTemperature: $tmpBiomeTemperature');
		}

		return biomeTemperature;
	}

	public static function DoWorldMapTimeStuff() {
		// devide in X steps
		var timeParts = ServerSettings.WorldTimeParts;
		var worldMap = Server.server.map;

		var partSizeY = Std.int(worldMap.height / timeParts);
		var startY = (worldMapTimeStep % timeParts) * partSizeY;
		var endY = startY + partSizeY;

		// trace('startY: $startY endY: $endY worldMap.height: ${worldMap.height}');

		if(tick % 2000 == 0){
			// clear ovens, so that old ones go away
			var ovens = [for (obj in WorldMap.world.ovens) obj];
			var newovens = new Map<Int, ObjectHelper>();
			
			for(oven in ovens){
				// 237 Adobe Oven // 753 Adobe Rubble
				if(ObjectData.IsOven(oven.id) || oven.id == 753){
					var index = WorldMap.world.index(oven.tx, oven.ty);
					newovens[index] = oven;
				}
			}

			WorldMap.world.ovens = newovens;
		}

		if (worldMapTimeStep % timeParts == 0) {
			if (TimeTimeStepsSartedInTicks > 0) TimePassedToDoAllTimeSteps = TimeHelper.CalculateTimeSinceTicksInSec(TimeTimeStepsSartedInTicks);

			// trace('DOTIME: started: $TimeTimeStepsSartedInTicks passed: $TimePassedToDoAllTimeSteps');

			WinterDecayChance = TimePassedToDoAllTimeSteps * ServerSettings.WinterWildFoodDecayChance / (TimeToNextSeasonInYears * 60);
			SpringRegrowChance = TimePassedToDoAllTimeSteps * ServerSettings.SpringWildFoodRegrowChance / (TimeToNextSeasonInYears * 60);

			WinterDecayChance *= SeasonHardness;
			SpringRegrowChance *= SeasonHardness;

			TimeTimeStepsSartedInTicks = tick;

			// trace('DOTIME: winterDecayChance: $winterDecayChance springRegrowChance: $springRegrowChance');
		}

		worldMapTimeStep++;

		for (y in startY...endY) {
			for (x in 0...worldMap.width) {
				if (Season == Seasons.Spring) {			
					var hiddenObj = worldMap.getHiddenObjectId(x, y);
					if (hiddenObj[0] != 0) RespawnOrDecayPlant(hiddenObj, x, y, true);

					var originalObj = worldMap.getOriginalObjectId(x, y);
					if (originalObj[0] != 0) RespawnOrDecayPlant(originalObj, x, y, false, ServerSettings.GrowBackOriginalPlantsFactor);
				}

				var obj = worldMap.getObjectId(x, y);

				if (obj[0] == 0) continue;

				DoSecondTimeOutcome(x, y, obj[0], TimePassedToDoAllTimeSteps);

				var biome = worldMap.getBiomeId(x, y);

				// add possible spawn localtions
				if (obj[0] == 30) WorldMap.world.berryBushes[WorldMap.world.index(x,
					y)] = worldMap.getObjectHelper(x, y); // Wild Gooseberry Bush ==> possible spawn location
				if (obj[0] == 2142) WorldMap.world.bananaPlants[WorldMap.world.index(x,
					y)] = worldMap.getObjectHelper(x, y); // Banana Plant ==> possible spawn location
				if (obj[0] == 36 && biome == BiomeTag.SNOW) WorldMap.world.wildCarrots[WorldMap.world.index(x,
					y)] = worldMap.getObjectHelper(x, y); // Seeding Wild Carrot ==> possible spawn location
				if (obj[0] == 761 && biome == BiomeTag.DESERT) WorldMap.world.cactuses[WorldMap.world.index(x,
					y)] = worldMap.getObjectHelper(x, y); // Barrel Cactus ==> possible spawn location
				if (obj[0] == 4251 && biome == BiomeTag.GREY) WorldMap.world.wildGarlics[WorldMap.world.index(x,
					y)] = worldMap.getObjectHelper(x, y); // Wild Garlic ==> possible spawn location
				
				// get possible teleport locations
				// 237 Adobe Oven // 753 Adobe Rubble
				if(ObjectData.IsOven(obj[0]) || obj[0] == 753) WorldMap.world.ovens[WorldMap.world.index(x,
					y)] = worldMap.getObjectHelper(x, y);

				var floorId = worldMap.getFloorId(x,y);
				//1596 = Stone Road
				if(floorId == 1596) WorldMap.world.roads[WorldMap.world.index(x,
						y)] = worldMap.getObjectHelper(x, y); 

				RespawnOrDecayPlant(obj, x, y);

				var helper = worldMap.getObjectHelper(x, y, true);

				if (helper != null) {
					if (helper.timeToChange == 0) // maybe timeToChange was forgotten to be set
					{
						var timeTransition = TransitionImporter.GetTransition(-1, helper.id, false, false);

						if (timeTransition == null) continue;

						trace('WARNING: found helper without time transition: ${helper.description}: ' + timeTransition.getDesciption());

						helper.timeToChange = timeTransition.calculateTimeToChange();
					}

					// clear up not needed ObjectHelpers to save space
					if (worldMap.deleteObjectHelperIfUseless(helper)) continue; // uses worlmap mutex

					TimeHelper.doTimeTransition(helper);

					continue;
				}

				var timeTransition = TransitionImporter.GetTransition(-1, obj[0], false, false);
				if (timeTransition == null) continue;

				helper = worldMap.getObjectHelper(x, y);
				helper.timeToChange = timeTransition.calculateTimeToChange();

				worldMap.setObjectHelper(x, y, helper);

				// trace('TIME: ${helper.objectData.description} neededTime: ${timeToChange}');

				// var testObj = getObjectId(helper.tx, helper.ty);

				// trace('testObj: $testObj obj: $obj ${helper.tx},${helper.ty} i:$i index:${index(helper.tx, helper.ty)}');
			}
		}
	}

	private static function DoSecondTimeOutcome(tx:Int, ty:Int, objId, timepassed:Float)
	{
		var objData = ObjectData.getObjectData(objId);
		if(objData.secondTimeOutcome < 1 || objData.secondTimeOutcomeTimeToChange < 1) return;

		if(timepassed / objData.secondTimeOutcomeTimeToChange < WorldMap.calculateRandomFloat()) return;

		var obj = WorldMap.world.getObjectHelper(tx,ty);

		/*if(obj == null)
		{
			obj = re
			var ids = [objData.secondTimeOutcome];
			WorldMap.world.setObjectId(tx,ty,ids);
			Connection.SendMapUpdateToAllClosePlayers(tx,ty, ids);
			return;
		}*/


		obj.id = objData.secondTimeOutcome;
		WorldMap.world.setObjectHelper(tx,ty, obj);
		Connection.SendMapUpdateToAllClosePlayers(tx,ty);
	}

	private static function RespawnOrDecayPlant(objIDs:Array<Int>, x:Int, y:Int, hidden:Bool = false, growFactor:Float = 1) {
		var objID = objIDs[0];
		var objData = ObjectData.getObjectData(objID);

		if (Season == Seasons.Winter && hidden == false && objData.winterDecayFactor > 0) {
			// reduce uses if it is for example a berry bush
			if (objData.numUses > 1) {
				var objHelper = WorldMap.world.getObjectHelper(x, y);

				if (WinterDecayChance * objData.winterDecayFactor * objHelper.numberOfUses < WorldMap.calculateRandomFloat()) return;

				WorldMap.world.mutex.acquire(); // TODO try catch // TODO object helper may have changed

				objHelper.numberOfUses -= 1;
				objHelper.TransformToDummy();
				WorldMap.world.setObjectHelper(x, y, objHelper);

				WorldMap.world.mutex.release();

				Connection.SendMapUpdateToAllClosePlayers(x, y);

				return;
			}

			if (WinterDecayChance * objData.winterDecayFactor < WorldMap.calculateRandomFloat()) return;

			var random = WorldMap.calculateRandomFloat();

			WorldMap.world.mutex.acquire(); // TODO try catch

			WorldMap.world.setObjectId(x, y, [0]);
			if (objData.springRegrowFactor > random) WorldMap.world.setHiddenObjectId(x, y, objIDs); // TODO hide also object helper for advanced objects???

			Connection.SendMapUpdateToAllClosePlayers(x, y);

			WorldMap.world.currentObjectsCount[objID]--;

			WorldMap.world.mutex.release(); // TODO try catch

			if (ServerSettings.DebugSeason) {
				var mod = WorldMap.world.currentObjectsCount[objID] < 1000 ? 100 : 1000;
				mod = WorldMap.world.currentObjectsCount[objID] < 100 ? 10 : mod;
				mod = WorldMap.world.currentObjectsCount[objID] < 10 ? 1 : mod;
				if (WorldMap.world.currentObjectsCount[objID] % mod == 0)
					trace('SEASON DECAY: ${objData.description} ${WorldMap.world.currentObjectsCount[objID]} original: ${WorldMap.world.originalObjectsCount[objID]}');
			}
		} else if (Season == Seasons.Spring && objData.springRegrowFactor > 0) {
			// TODO regrow also from originalObjects?

			// increase uses if it is for example a berry bush
			if (objData.numUses > 1 || objData.undoLastUseObject != 0) {
				var objHelper = WorldMap.world.getObjectHelper(x, y);
				if (objHelper.numberOfUses >= objData.numUses && objData.undoLastUseObject == 0) return;

				var factor = objData.numUses - objHelper.numberOfUses;
				if (factor < 1) factor = 1;

				if (SpringRegrowChance * objData.springRegrowFactor * factor < WorldMap.calculateRandomFloat()) return;

				WorldMap.world.mutex.acquire(); 
				Macro.exception(IncreaseNumberOfUses(objHelper));
				WorldMap.world.mutex.release();

				Connection.SendMapUpdateToAllClosePlayers(x, y);

				return;
			}

			var factor = hidden ? 2 : 0.2;
			factor *= growFactor;

			if (SpringRegrowChance * objData.springRegrowFactor * factor < WorldMap.calculateRandomFloat()) return;

			var spawnAs = objData.countsOrGrowsAs > 0 ? objData.countsOrGrowsAs : objID;

			WorldMap.world.mutex.acquire();
			Macro.exception(RegrowObj(x,y, spawnAs, hidden));
			WorldMap.world.mutex.release();

			if (ServerSettings.DebugSeason) {
				var mod = WorldMap.world.currentObjectsCount[spawnAs] < 1000 ? 100 : 1000;
				mod = WorldMap.world.currentObjectsCount[spawnAs] < 100 ? 10 : mod;
				mod = WorldMap.world.currentObjectsCount[spawnAs] < 10 ? 1 : mod;
				if (WorldMap.world.currentObjectsCount[spawnAs] % mod == 0)
					trace('SEASON REGROW: ${objData.description} ${WorldMap.world.currentObjectsCount[spawnAs]} original: ${WorldMap.world.originalObjectsCount[spawnAs]}');
			}
		}
	}

	private static function IncreaseNumberOfUses(objHelper:ObjectHelper){
		objHelper.numberOfUses += 1;
		objHelper.TransformToDummy();
		WorldMap.world.setObjectHelper(objHelper.tx, objHelper.ty, objHelper);
	}

	private static function RegrowObj(tx:Int, ty:Int, spawnAs:Int, hidden:Bool) : Bool{
		var floorId = WorldMap.world.getFloorId(tx,ty);
		if (floorId > 0) return false;
		var done = SpawnObject(tx, ty, spawnAs);
		if (hidden && done) WorldMap.world.setHiddenObjectId(tx, ty, [0]); // What was hidden comes back
		return done;
	}

	public static function RespawnObjects() {
		var timeParts = ServerSettings.WorldTimeParts * 10;
		var worldMap = Server.server.map;
		var partSizeY = Std.int(worldMap.height / timeParts);
		var startY = (worldMapTimeStep % timeParts) * partSizeY;
		var endY = startY + partSizeY;

		// trace('startY: $startY endY: $endY worldMap.height: ${worldMap.height}');

		for (y in startY...endY) {
			for (x in 0...worldMap.width) {
				var objID = worldMap.getOriginalObjectId(x, y)[0];

				if (objID == 0) continue;

				if (ServerSettings.CanObjectRespawn(objID) == false) continue;

				if (ServerSettings.ObjRespawnChance < worldMap.randomFloat()) continue;

				WorldMap.world.mutex.acquire(); // TODO try catch

				SpawnObject(x, y, objID);

				WorldMap.world.mutex.release(); // TODO try catch

				// trace('respawn object: ${objData.description} $obj');
			}
		}
	}

	public static function SpawnObject(x:Int, y:Int, objID:Int, dist:Int = 6, tries:Int = 3):Bool {
		var worldMap = WorldMap.world;

		if (worldMap.currentObjectsCount[objID] >= worldMap.originalObjectsCount[objID]) return false;

		for (ii in 0...tries) {
			var tmpX = worldMap.randomInt(2 * dist) - dist + x;
			var tmpY = worldMap.randomInt(2 * dist) - dist + y;

			if (worldMap.getObjectId(tmpX, tmpY)[0] != 0) continue;
			if (worldMap.getObjectId(tmpX, tmpY - 1)[0] != 0) continue; // make sure that obj does not spawn above one tile of existing obj
			if (worldMap.getFloorId(tmpX, tmpY) != 0) continue; // dont spawn on floors

			var biomeId = worldMap.getBiomeId(tmpX, tmpY);
			var objData = ObjectData.getObjectData(objID);

			if (objData.isSpawningIn(biomeId) == false) continue;

			worldMap.setObjectId(tmpX, tmpY, [objID]);

			worldMap.currentObjectsCount[objID]++;

			Connection.SendMapUpdateToAllClosePlayers(tmpX, tmpY);

			return true;
		}

		return false;
	}

	public static function DoWorldLongTermTimeStuff() {
		// TODO dont decay if some on is close?
		// TODO decay stuff in containers
		// TODO decay stuff with number of uses > 1
		// TODO set custom objDecayTo
		// TODO add decay object so that decay is visible ==> 618 Filled Small Trash Pit

		var timeParts = ServerSettings.WorldTimeParts * 10;
		var worldMap = Server.server.map;
		var partSizeY = Std.int(worldMap.height / timeParts);
		var startY = (worldMapTimeStep % timeParts) * partSizeY;
		var endY = startY + partSizeY;

		//trace('DOLONGTIME: $worldMapTimeStep from $timeParts');

		if (worldMapTimeStep % timeParts == 0) {
			if (LongTimeTimeStepsSartedInTicks > 0) LongTimePassedToDoAllTimeSteps = TimeHelper.CalculateTimeSinceTicksInSec(LongTimeTimeStepsSartedInTicks);

			trace('DOLONGTIME: $tick started: $LongTimeTimeStepsSartedInTicks passed: ${LongTimePassedToDoAllTimeSteps}');

			LongTimeTimeStepsSartedInTicks = tick;
		}

		//var timePassedInSec = LongTimeTimeStepsSartedInTicks;
		var season = TimeHelper.Season;
		var timePassedInYears = LongTimePassedToDoAllTimeSteps / 60;

		// trace('startY: $startY endY: $endY worldMap.height: ${worldMap.height}');

		for (y in startY...endY) {
			for (x in 0...worldMap.width) {
				var objId = worldMap.getObjectId(x, y)[0];
				var floorId = worldMap.getFloorId(x,y);
				var biomeId = worldMap.getBiomeId(x,y);
				var biomeDecayFactor:Float = Biome.getBiomeDecayFactor(biomeId);

				DoSeasonalBiomeChanges(x, y, timePassedInYears);

				if(objId == 0 && floorId == 0 && season == Spring) DoRespawnFromOriginal(x, y, timePassedInYears);
				
				// decay floor
				if(objId == 0 && floorId > 0){
					var objData = ObjectData.getObjectData(floorId);
					var decayChance = ServerSettings.FloorDecayChance * objData.decayFactor;
					decayChance *= biomeDecayFactor;

					if (worldMap.randomFloat() < decayChance) {
						var decaysToObj = objData.decaysToObj == 0 ? 618 : objData.decaysToObj; // 618 Filled Small Trash Pit
						var decaysToObjData = ObjectData.getObjectData(decaysToObj);

						if(decaysToObjData.floor) worldMap.setFloorId(x,y,decaysToObj);
						else{
							worldMap.setFloorId(x,y,0);
							worldMap.setObjectId(x,y,[decaysToObj]);
						}

						Connection.SendMapUpdateToAllClosePlayers(x, y);

						trace('Floor ${objData.name} decayed to: ${decaysToObjData.name}');
					}
				}

				if (objId == 0) continue;

				if (ServerSettings.CanObjectRespawn(objId) == false) continue;

				if (worldMap.currentObjectsCount[objId] <= worldMap.originalObjectsCount[objId]) continue; // dont decay natural stuff if there are too few

				var objectHelper = worldMap.getObjectHelper(x, y, true);

				if (objectHelper != null && objectHelper.containedObjects.length > 0) continue; // TODO change

				if (objectHelper != null && objectHelper.timeToChange > 0) continue; // dont decay object if there is a time transition

				var objData = ObjectData.getObjectData(objId);

				if (objData.decayFactor <= 0) continue;

				var decayChance = ServerSettings.ObjDecayChance * objData.decayFactor;
				decayChance *= biomeDecayFactor;
				
				if (objData.foodValue > 0) decayChance *= ServerSettings.ObjDecayFactorForFood;

				if (worldMap.getFloorId(x, y) != 0) decayChance *= ServerSettings.ObjDecayFactorOnFloor;

				if (objData.permanent > 0) decayChance *= ServerSettings.ObjDecayFactorForPermanentObjs;
				//if (objData.permanent <= 0) trace('decay not permanent: ${objData.description}');

				if (worldMap.randomFloat() > decayChance) continue;

				// if(objData.isSpawningIn(biomeId) == false) continue;

				var decaysToObj = objData.decaysToObj; 
				if(decaysToObj == 0 && objData.permanent > 0) decaysToObj = 618; // 618 Filled Small Trash Pit

				worldMap.setObjectId(x, y, [decaysToObj]);
				// worldMap.setObjectHelperNull(x, y);

				worldMap.currentObjectsCount[objId]--;

				Connection.SendMapUpdateToAllClosePlayers(x, y);

				trace('decay object: ${objData.description} $objId');
			}
		}
	}
	
	// TODO find a better way to respawn this stuff??? 
	public static function DoRespawnFromOriginal(tx:Int, ty:Int, passedTimeInYears:Float) {
		var world = WorldMap.world;
		var origObj = world.getOriginalObjectId(tx,ty);
		
		if (origObj[0] == 50) // Milkweed
		{
			if(world.randomFloat() < passedTimeInYears  / 60){
				world.setObjectId(tx,ty, [50]);
			}
		}
		else if (origObj[0] == 136) // Sapling
		{
			if(world.randomFloat() < passedTimeInYears / (60 * 2)){
				world.setObjectId(tx,ty, [136]);
			}
		}
		else if (origObj[0] == 1261) // 1261 Canada Goose Pond with Egg
		{
			if(world.randomFloat() < passedTimeInYears / (60 * 24)){
				world.setObjectId(tx,ty, [1261]);
			}
		}
	}

	public static function DoSeasonalBiomeChanges(tx:Int, ty:Int, timePassedInYears:Float) {
		var world = WorldMap.world;

		//Season = Winter;
		
		if (Season == Seasons.Winter){
			var biomeId = world.getBiomeId(tx,ty);

			if(biomeId != SNOW && biomeId != BiomeTag.SNOWINGREY) return;
			
			var chance = timePassedInYears * ServerSettings.SeasonBiomeChangeChancePerYear * 4; // 4 because 4 directions
			if (world.randomFloat() > chance) return;

			var objData = world.getObjectDataAtPosition(tx,ty);
			var insulation = objData.getInsulation();
			if(insulation > 0){
				if (objData.isClothing() == false && insulation > world.randomFloat()){
					//trace('DoSeasonalBiomeChanges: ${objData.name} Insulation: $insulation ==> no snow');
					return;
				}
			}

			var rand = world.randomInt(3);
			var randX = tx;
			var randY = ty;

			if(rand == 0) randX = tx + 1;
			else if(rand == 1) randX = tx - 1;
			else if(rand == 2) randY = ty + 1;
			else if(rand == 3) randY = ty - 1;

			//var randX = tx - 1 + world.randomInt(2);
			//var randY = ty - 1 + world.randomInt(2);
			var biomeId = world.getBiomeId(randX,randY);
			var doChange = true;
			
			if(biomeId != GREY && biomeId != YELLOW && biomeId != GREEN && biomeId != PASSABLERIVER) doChange = false;

			if(doChange) world.setBiomeId(randX,randY, SNOW);

			// also diagonal
			var randX = tx + 1 - world.randomInt(2);
			var randY = ty + 1 - world.randomInt(2);

			//var randX = tx - 1 + world.randomInt(2);
			//var randY = ty - 1 + world.randomInt(2);
			var biomeId = world.getBiomeId(randX,randY);
			
			if(biomeId != GREY && biomeId != YELLOW && biomeId != GREEN && biomeId != PASSABLERIVER) return;

			world.setBiomeId(randX,randY, SNOW);

			//trace('DoSeasonalBiomeChanges: $randX $randY');
		}
		if (Season == Seasons.Summer || Season == Seasons.Spring){
			var biomeId = world.getBiomeId(tx,ty);

			if(biomeId != SNOW) return;
			
			var chance = timePassedInYears * ServerSettings.SeasonBiomeChangeChancePerYear * 4; // 4 because 4 directions
			chance *= ServerSettings.SeasonBiomeRestoreFactor;
			if (world.randomFloat() > chance) return;

			var rand = world.randomInt(3);
			var randX = tx;
			var randY = ty;
			
			if(rand == 0) randX = tx + 1;
			else if(rand == 1) randX = tx - 1;
			else if(rand == 2) randY = ty + 1;
			else if(rand == 3) randY = ty - 1;

			var biomeId = world.getBiomeId(randX,randY);
			var doChange = true;
			
			if(biomeId == SNOW || biomeId == SNOWINGREY) doChange = false;

			var originalBiome = world.getOriginalBiomeId(tx,ty);

			if(doChange) world.setBiomeId(tx,ty, originalBiome);

			// also diagonal
			var randX = tx + 1 - world.randomInt(2);
			var randY = ty + 1 - world.randomInt(2);

			var biomeId = world.getBiomeId(randX,randY);
			var doChange = true;
			
			if(biomeId == SNOW || biomeId == SNOWINGREY) doChange = false;

			var originalBiome = world.getOriginalBiomeId(tx,ty);

			if(doChange) world.setBiomeId(tx,ty, originalBiome);

			//trace('DoSeasonalBiomeChanges: $randX $randY originalBiome: $originalBiome');
		}
	}

	//public static function DecayObjects() {}

	public static function doTimeTransition(helper:ObjectHelper) {
		if (helper.isTimeToChangeReached() == false) return;
		// trace('TIME: ${helper.objectData.description} passedTime: $passedTime neededTime: ${timeToChange}');

		// TODO test time transition for maxUseTaget like Goose Pond:
		// -1 + 142 = 0 + 142
		// -1 + 142 = 0 + 141

		WorldMap.world.mutex.acquire();

		// just to be sure, that no other thread changed object meanwhile

		if (helper != WorldMap.world.getObjectHelper(helper.tx, helper.ty)) {
			WorldMap.world.mutex.release();

			trace("TIME: some one changed helper meanwhile");

			return;
		}

		var sendUpdate = false;

		Macro.exception(sendUpdate = doTimeTransitionHelper(helper));

		WorldMap.world.mutex.release();

		if (sendUpdate == false) return;

		Connection.SendMapUpdateToAllClosePlayers(helper.tx, helper.ty);
	}

	public static function doTimeTransitionHelper(helper:ObjectHelper):Bool {
		var tx = helper.tx;
		var ty = helper.ty;

		var tileObject = Server.server.map.getObjectId(tx, ty);
		//var objData = ObjectData.getObjectData(tileObject[0]);
		//trace('Time: tileObject: $tileObject ${objData.name}');

		var transition = TransitionImporter.GetTransition(-1, tileObject[0], false, false);

		if (transition == null) {
			helper.timeToChange = 0;
			WorldMap.world.setObjectHelperNull(tx, ty);
			// FIX 4773 rabbit bones 
			trace('WARNING: Time: no transtion found! Maybe object was moved? tile: $tileObject helper: ${helper.id} ${helper.description}');
			return false;
		}

		var newObjectData = ObjectData.getObjectData(transition.newTargetID);

		// for example if a grave with objects decays
		if (helper.containedObjects.length > newObjectData.numSlots) {
			// check in another 20 sec
			helper.timeToChange += 20;

			var containedObject = helper.containedObjects.pop();

			// For each Sharp Stone a grave needs much longer to decay / This can be used to let cursed graves exist much longer
			if (containedObject.id == 34) {
				helper.timeToChange += ServerSettings.CursedGraveTime * 60 * 60;
				ScoreEntry.CreateScoreEntryForCursedGrave(helper);
			}

			WorldMap.PlaceObject(tx, ty, containedObject);

			trace('time: placed object ${containedObject.description} from ${helper.description}');

			// trace('time: could not decay newTarget cannot store contained objects! ${helper.description}');

			return false;
		}

		if (transition.move > 0) {
			Macro.exception(doAnimalMovement(helper, transition));
			return false;
		}

		ScoreEntry.CreateScoreEntryIfGrave(helper);

		if (helper.isLastUse()){
			var tmpTransition = TransitionImporter.GetTransition(-1, helper.id, false, true);
			if(tmpTransition != null) transition = tmpTransition;
			else{
				var objData = ObjectData.getObjectData(tileObject[0]);
				var name = objData == null ? '' : objData.name;
				trace('WARNING: TIME: $tileObject ${name} isLastUse transition not found!');
			}
		}

		// can have different random outcomes like Blooming Squash Plant
		helper.id = TransitionHelper.TransformTarget(transition.newTargetID);
		helper.timeToChange = ObjectHelper.CalculateTimeToChangeForObj(helper);
		helper.creationTimeInTicks = TimeHelper.tick;

		TransitionHelper.DoChangeNumberOfUsesOnTarget(helper, transition, null, false);

		WorldMap.world.setObjectHelper(tx, ty, helper);

		return true;
	}

	/*
		MX
		x y new_floor_id new_id p_id old_x old_y speed

		Optionally, a line can contain old_x, old_y, and speed.
		This indicates that the object came from the old coordinates and is moving
		with a given speed.
	 */
	private static function doAnimalMovement(helper:ObjectHelper, timeTransition:TransitionData):Bool {
		// TODO chasing
		// TODO fleeing
		// TODO Offspring only if with child
		// TODO eating meat / killing sheep

		var moveDist = timeTransition.move;
		if (moveDist <= 0) return false;
		if(moveDist > 3) moveDist = 3;
		timeTransition.move = 3;

		if (moveDist < 3) moveDist += 1; // movement distance is plus 4 in vanilla if walking over objects
		helper.objectData.moves = moveDist; // TODO better set in settings

		if (helper.hits > 0) helper.hits -= 0.005; // reduce hits the animal got
		if (helper.hits < 0) helper.hits = 0;

		var worldmap = Server.server.map;
		var objectData = helper.objectData.dummyParent == null ? helper.objectData : helper.objectData.dummyParent;
		var fromTx = helper.tx;
		var fromTy = helper.ty;
		var currentbiome = worldmap.getBiomeId(helper.tx, helper.ty);
		var lovesCurrentBiome = objectData.isSpawningIn(currentbiome);

		if (lovesCurrentBiome) {
			// trace('set loved tx,ty for animal: ${helper.description}');
			helper.lovedTx = helper.tx;
			helper.lovedTy = helper.ty;
		}

		var maxIterations = 20;
		var besttarget = null;
		var bestQuadDist = 999999999999999999999999999999999.9;

		for (i in 0...maxIterations) {
			var toTx = helper.tx - moveDist + worldmap.randomInt(moveDist * 2);
			var toTy = helper.ty - moveDist + worldmap.randomInt(moveDist * 2);

			var target = worldmap.getObjectHelper(toTx, toTy);

			if (target.id != 0) continue;

			if (target.blocksWalking()) continue;
			// dont move move on top of other moving stuff
			if (target.timeToChange != 0) continue;
			if (target.groundObject != null) continue;
			// make sure that target is not the old tile
			if (toTx == helper.tx && toTy == helper.ty) continue;

			var targetBiome = worldmap.getBiomeId(toTx, toTy);

			if (WorldMap.isBiomeBlocking(toTx, toTy)) continue;

			var isPreferredBiome = objectData.isSpawningIn(targetBiome);

			// if(helper.objectData.dummyParent != null) trace('Animal Move: ${objectData.description} $isPreferredBiome');

			// lower the chances even more if on river
			// var isHardbiome = targetBiome == BiomeTag.RIVER || (targetBiome == BiomeTag.GREY) || (targetBiome == BiomeTag.SNOW) || (targetBiome == BiomeTag.DESERT);
			var isNotHardbiome = isPreferredBiome || targetBiome == BiomeTag.GREEN || targetBiome == BiomeTag.YELLOW;

			var chancePreferredBiome = isNotHardbiome ? ServerSettings.chancePreferredBiome : (ServerSettings.chancePreferredBiome + 4) / 5;

			// trace('chance: $chancePreferredBiome isNotHardbiome: $isNotHardbiome biome: $targetBiome');

			// skip with chancePreferredBiome if this biome is not preferred
			if (isPreferredBiome == false && i < 5 && worldmap.randomFloat() <= chancePreferredBiome) continue;

			// limit movement if blocked
			target = calculateNonBlockedTarget(fromTx, fromTy, target);
			if (target == null) continue; // movement was fully bocked, search another target

			// try to go closer to loved biome
			if (lovesCurrentBiome == false && isPreferredBiome == false && (helper.lovedTx != 0 || helper.lovedTy != 0)) {
				var quadDist = AiHelper.CalculateDistance(helper.lovedTx, helper.lovedTy, target.tx, target.ty);
				if (quadDist < bestQuadDist) {
					bestQuadDist = quadDist;
					besttarget = target;
					maxIterations = i + 6; // try to find better

					// trace('i: $i set better target for animal: ${helper.description} quadDist: $quadDist');
				}

				if (i < maxIterations - 2) continue; // try to find better

				if (besttarget != null) target = besttarget;

				// Connection.SendLocationToAllClose(helper.lovedTx, helper.lovedTy, helper.name);

				// toTx = toTx > helper.lovedTx ? toTx - 1 : toTx + 1;
			}

			toTx = target.tx;
			toTy = target.ty;

			// 2710 + -1 = 767 + 769 // Wild Horse with Lasso + TIME  -->  Lasso# tool + Wild Horse
			var transition = TransitionImporter.GetTransition(helper.parentId, -1, false, false);

			if (transition != null) {
				var tmpGroundObject = helper.groundObject;
				helper.groundObject = new ObjectHelper(null, transition.newActorID);
				helper.groundObject.groundObject = tmpGroundObject;

				// trace('animal movement: found -1 transition: ${helper.description} --> ${helper.groundObject.description}');
			}

			if (helper.isLastUse()) timeTransition = TransitionImporter.GetTransition(-1, helper.id, false, true);

			// FIX: 544 Domestic Mouflon with Lamb + -1  ==> 545 Domestic Lamb + 541 Domestic Mouflon
			var timeAlternaiveTransition = (helper.isLastUse()) ? TransitionImporter.GetTransition(helper.id, -1, true, false) : null;

			helper.id = timeAlternaiveTransition != null ? timeAlternaiveTransition.newTargetID : timeTransition.newTargetID;

			TransitionHelper.DoChangeNumberOfUsesOnTarget(helper, timeTransition, false);

			// save what was on the ground, so that we can move on this tile and later restore it
			var oldTileObject = helper.groundObject == null ? [0] : helper.groundObject.toArray();
			var newTileObject = helper.toArray();

			// var des = helper.groundObject == null ? "NONE": helper.groundObject.description();
			// trace('MOVE: oldTile: $oldTileObject $des newTile: $newTileObject ${helper.description()}');
			if(timeAlternaiveTransition == null){
				worldmap.setObjectHelper(fromTx, fromTy, helper.groundObject);
			}
			else{
				// FIX: 544 Domestic Mouflon with Lamb + -1  ==> 545 Domestic Lamb + 541 Domestic Mouflon
				// TODO what to do with the old tile obj in case an animal moved on top of stuff?
				oldTileObject = [timeAlternaiveTransition.newActorID];
				worldmap.setObjectId(fromTx, fromTy, oldTileObject);

				trace('timeAlternaiveTransition: ${timeAlternaiveTransition.getDesciption()}');
			}

			var tmpGroundObject = helper.groundObject;
			helper.groundObject = target;
			worldmap.setObjectHelper(toTx, toTy, helper); // set so that object has the right position before doing damage
			// helper.tx = toTx;
			// helper.ty = toTy;
			var damage = DoAnimalDamage(fromTx, fromTy, helper);
			// TODO only change after movement is finished
			if (damage <= 0) helper.timeToChange = timeTransition.calculateTimeToChange();
			helper.creationTimeInTicks = TimeHelper.tick;

			worldmap.setObjectHelper(toTx, toTy, helper); // set again since animal might be killed

			var chanceForOffspring = isPreferredBiome ? ServerSettings.ChanceForOffspring : ServerSettings.ChanceForOffspring * Math.pow((1
				- chancePreferredBiome), 2);
			var chanceForAnimalDying = isPreferredBiome ? ServerSettings.ChanceForOffspring / 2 : ServerSettings.ChanceForAnimalDying;

			// give extra birth chance bonus if population is very low
			if (worldmap.currentObjectsCount[newTileObject[0]] < worldmap.originalObjectsCount[newTileObject[0]] / 2) chanceForOffspring *= ServerSettings.OffspringFactorIfAnimalPopIsLow;

			if (worldmap.currentObjectsCount[newTileObject[0]] < worldmap.originalObjectsCount[newTileObject[0]] * ServerSettings.MaxOffspringFactor
				&& worldmap.randomFloat() <= chanceForOffspring) {
				worldmap.currentObjectsCount[newTileObject[0]] += 1;

				// if(chanceForOffspring < worldmap.chanceForOffspring) trace('NEW: $newTileObject ${helper.description()}: ${worldmap.currentPopulation[newTileObject[0]]} ${worldmap.initialPopulation[newTileObject[0]]} chance: $chanceForOffspring biome: $targetBiome');

				oldTileObject = newTileObject;

				var newAnimal = ObjectHelper.readObjectHelper(null, newTileObject);
				newAnimal.timeToChange = timeTransition.calculateTimeToChange();
				newAnimal.groundObject = tmpGroundObject;
				worldmap.setObjectHelper(fromTx, fromTy, newAnimal);
			} else if (worldmap.currentObjectsCount[newTileObject[0]] > worldmap.originalObjectsCount[newTileObject[0]] * ServerSettings.MaxOffspringFactor
				&& worldmap.originalObjectsCount[newTileObject[0]] > 0 && worldmap.randomFloat() <= chanceForAnimalDying) {
				// decay animal only if it is a original one
				// TODO decay all animals and cosider if they cointain items like a horse wagon
				// trace('Animal DEAD: $newTileObject ${helper.description}: Count: ${worldmap.currentObjectsCount[newTileObject[0]]} Original Count: ${worldmap.originalObjectsCount[newTileObject[0]]} chance: $chanceForAnimalDying biome: $targetBiome');

				helper.id = 0;
				newTileObject = [0];
				worldmap.setObjectHelper(toTx, toTy, helper);
			}

			var speed = ServerSettings.InitialPlayerMoveSpeed * objectData.speedMult;
			Connection.SendAnimalMoveUpdateToAllClosePlayers(fromTx, fromTy, toTx, toTy, oldTileObject, newTileObject, speed);

			// trace('ANIMALMOVE: true $i');

			return true;
		}

		helper.creationTimeInTicks = TimeHelper.tick;
		// trace('ANIMALMOVE: false');

		return false;
	}

	public static function TryAnimaEscape(attacker:GlobalPlayerInstance, target:ObjectHelper):Bool {
		var weapon = attacker.heldObject;
		var animalEscapeFactor = weapon.objectData.animalEscapeFactor - target.hits * 0.25;
		var random = WorldMap.calculateRandomFloat();

		trace('TryAnimaEscape: ${target.hits} $random > $animalEscapeFactor');
		target.hits += 1;

		if (random > animalEscapeFactor) return false;

		target.timeToChange /= 5;
		var tmpTimeToChange = target.timeToChange;
		doTimeTransition(target);

		var escaped = tmpTimeToChange != target.timeToChange;
		trace('TryAnimaEscape: $escaped');
		if (escaped == false) return false;

		if (weapon.id == 152) // Bow and Arrow
		{
			weapon.id = 749; // 151 Bow // 749 Bloody Yew Bow
			attacker.setHeldObject(weapon);
			attacker.setHeldObjectOriginNotValid(); // no animation
			weapon.timeToChange = 2;

			WorldMap.PlaceObject(target.tx, target.ty, new ObjectHelper(attacker, 798), true); // Place Arrow Wound
		}

		return true;
	}

	public static function MakeAnimalsRunAway(player:GlobalPlayerInstance, searchDistance:Int = 1) {
		// AiHelper.GetClosestObject
		var world = WorldMap.world;
		var baseX = player.tx;
		var baseY = player.ty;

		for (ty in baseY - searchDistance...baseY + searchDistance) {
			for (tx in baseX - searchDistance...baseX + searchDistance) {
				var obj = world.getObjectHelper(tx, ty, true);
				if (obj == null) continue;
				if (obj.objectData.moves == 0) continue;

				var tmpTimeToChange = obj.timeToChange;
				obj.timeToChange /= 5;
				
				// release GlobalPlayermutex before trying to aquire world mutex, since doTimeTransition needs the world mutex. Always aquire world mutex first!
				if(ServerSettings.UseOneSingleMutex == false) GlobalPlayerInstance.ReleaseMutex(); 
				Macro.exception(doTimeTransition(obj));
				if(ServerSettings.UseOneSingleMutex == false) GlobalPlayerInstance.AcquireMutex();

				// trace('RUN: $tmpTimeToChange --> ${obj.timeToChange} ' + obj.description);
				// obj.timeToChange = tmpTimeToChange;
			}
		}
	}

	private static function calculateNonBlockedTarget(fromX:Int, fromY:Int, toTarget:ObjectHelper):ObjectHelper {
		var tx = toTarget.tx;
		var ty = toTarget.ty;
		var tmpX = fromX;
		var tmpY = fromY;
		var tmpTarget = null;

		for (ii in 0...10) {
			if (tmpX == tx && tmpY == ty) break;

			if (tx > tmpX) tmpX += 1; else if (tx < tmpX) tmpX -= 1;

			if (ty > tmpY) tmpY += 1; else if (ty < tmpY) tmpY -= 1;

			// trace('movement: $tmpX,$tmpY');

			var movementTileObj = WorldMap.worldGetObjectHelper(tmpX, tmpY);
			// var movementBiome = WorldMap.worldGetBiomeId(tmpX , tmpY);

			// var cannotMoveInBiome = movementBiome == BiomeTag.OCEAN ||  movementBiome == BiomeTag.SNOWINGREY;

			var isBiomeBlocking = WorldMap.isBiomeBlocking(tmpX, tmpY);

			if (isBiomeBlocking
				&& ServerSettings.ChanceThatAnimalsCanPassBlockingBiome > 0)
				isBiomeBlocking = WorldMap.calculateRandomFloat() > ServerSettings.ChanceThatAnimalsCanPassBlockingBiome;

			// TODO better patch in the objects, i dont see any reason why a rabit or a tree should block movement
			if (isBiomeBlocking
				|| (movementTileObj.blocksWalking())) {
					//&& movementTileObj.description.indexOf("Tarry Spot") == -1
					//&& movementTileObj.description.indexOf("Tree") == -1
					//&& movementTileObj.description.indexOf("Rabbit") == -1
					//&& movementTileObj.description.indexOf("Spring") == -1
					//&& movementTileObj.description.indexOf("Sugarcane") == -1
					//&& movementTileObj.description.indexOf("Pond") == -1
					//&& movementTileObj.description.indexOf("Palm") == -1
					//&& movementTileObj.description.indexOf("Plant") == -1)) {
					//&& movementTileObj.description.indexOf("Iron") == -1
				// trace('movement blocked ${movementTile.description()} ${movementBiome}');

				break;
			}

			// TODO allow move on non empty ground
			if (movementTileObj.id == 0) tmpTarget = movementTileObj;
		}

		return tmpTarget;
	}

	private static function DoAnimalDamage(fromX:Int, fromY:Int, animal:ObjectHelper):Float {
		var damage = 0.0;
		GlobalPlayerInstance.AcquireMutex();
		Macro.exception(damage = DoAnimalDamageHelper(fromX, fromY, animal));
		GlobalPlayerInstance.ReleaseMutex();

		return damage;
	}

	private static function DoAnimalDamageHelper(fromX:Int, fromY:Int, animal:ObjectHelper):Float {
		var objData = animal.objectData;

		if (objData.deadlyDistance <= 0) return 0;
		if (objData.damage <= 0) return 0;

		// trace('${objData.description} deadlyDistance: ${objData.deadlyDistance} damage: ${objData.damage}');
		var damage = 0.0;
		var tx = animal.tx;
		var ty = animal.ty;
		var tmpX = fromX;
		var tmpY = fromY;

		for (ii in 0...10) {
            //if (ii > 0 && tmpX == tx && tmpY == ty) break;

			for (p in GlobalPlayerInstance.AllPlayers) {
				if (p.deleted) continue;
				if (p.heldByPlayer != null) continue;
				if (p.isCloseUseExact(tmpX, tmpY, objData.deadlyDistance) == false) continue;

				trace('Do damage to: ${p.name}');
				damage += p.doDamage(animal);
				return damage;
			}

			if (tmpX == tx && tmpY == ty) break;
			if (tx > tmpX) tmpX += 1; else if (tx < tmpX) tmpX -= 1;
			if (ty > tmpY) tmpY += 1; else if (ty < tmpY) tmpY -= 1;
		}

		return damage;
	}

	// Called before time. Do tests here!
	private static function DoTest() {
		//var objData = ObjectData.getObjectData(2143); // Banana
		//var id = objData.getPileObjId();
		//trace('Pile: $id');

		// SerializeHelper.createReadWriteFile();
		/*
			var array = [];
			for(i in 0...1000000)
			{
				//array[WorldMap.calculateRandomInt(10)] += 1;
				//array[Math.floor(WorldMap.calculateRandomFloat() * 3)] += 1;
				//array[Math.round(Math.floor(Math.random() * 2))] += 1;
				if(WorldMap.calculateRandomFloat() > 0.5) array[0] += 1;
				else  array[1] += 1;
			}

			for(i in 0...2) trace('rand: $i: ' + array[i]); 
			*/

		// +biomeReq6 +biomeReq4 +biomeBlock4
		/*for(obj in ObjectData.importedObjectData)
			{
				if(StringTools.contains(obj.description, '+')) trace(obj.description);
		}*/

		return; // remove if testting
		var trans = TransitionImporter.GetTransition(418, 0, false, false);
		trace('TRANS4: $trans false, false');
		var trans = TransitionImporter.GetTransition(418, 0, true, false);
		trace('TRANS4: $trans true, false');
		// var trans = TransitionImporter.GetTransition(418, 0, true, false);
		// trace('TRANS: $trans');
	}

	// static var personIndex = 0;
	// static var colorIndex = 0;
	private static function DoTimeTestStuff() {
		if (tick % 200 == 0) {
			if (Connection.getConnections().length > 0) {
				/*
					var c = Connection.getConnections()[0];
					//FW follower_id leader_id leader_color_index
					c.send(ClientTag.FOLLOWING, ['${c.player.p_id} 2 $colorIndex']);
					//p_id emot_index
					c.send(ClientTag.PLAYER_EMOT, ['${c.player.p_id} $colorIndex']);
					//c.send(ClientTag.PLAYER_SAYS, ['0 0 $colorIndex']);
					//c.player.say('color $colorIndex');
					c.send(ClientTag.LOCATION_SAYS, ['100 0 /LEADER']);

					trace('FOLLOW '+ '${c.player.p_id} 2 $colorIndex');

					colorIndex++;

				 */
				/*
					c.player.po_id = obj.id;

					Connection.SendUpdateToAllClosePlayers(c.player);
					if(tick % 200 == 0) c.send(ClientTag.DYING, ['${c.player.p_id}']);
					else c.send(ClientTag.HEALED, ['${c.player.p_id}']);

					c.sendGlobalMessage('Id ${obj.parentId} P${obj.person} ${obj.description}');

					personIndex++;
					//  418 + 0 = 427 + 1363 / @ Deadly Wolf + Empty  -->  Attacking Wolf + Bite Wound 
				 */
			}
		}
	}
}
