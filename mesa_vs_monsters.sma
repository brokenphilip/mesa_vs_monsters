/*
	TODO:
	- (?) remove some useless ents
	- what to do with snarks/leeches
	- skill cvars?
	- extra points/money for specific monsters
	- extra points/money for dmg (use actual dmg, not cheesing fake 1hp immunity)
	- extra points/money for weapon used
	- calling Ham_Precache can be useful
	
	- after base is done, what's the direction of the plugin
	- upgrade station/buy menu/money system?
	- upgrade station should be a model, animation for open/close, maybe interaction? OR GMAN
	- waves?
	- custom map?
*/

#include <amxmodx>
#include <amxmisc>
#include <engine>
#include <fakemeta>
#include <fun>
#include <hamsandwich>
#include <hl>

#define PLUGIN "Mesa vs Monsters"
#define VERSION "0.1"
#define AUTHOR "brokenphilip"

#pragma semicolon 1

#define IS_PLAYER_ENT(%0) (1 <= %0 <= MAX_PLAYERS)
#define MAX_PLAYERS 32
#define MAX_ENTS 1380

#define TASK_TENTACLE 8419 // 8432 - 9799 (non-players can't be id < 33)
#define TASK_VERIFYNICK 9800 // 9801 - 9832
#define TASK_RENAME1 9833
#define TASK_RENAME2 9834 // 9835 - 9899

#define NO_ATTACKER gBotID

// CNihilanth offsets
#define M_IRRITATION 193 // 772/4

// bot name for use in the scoreboard
#define ENEMY_BOT "[Monsters]"

// w/o comments: 23
#define ENEMY_NUM 21
new const ENEMY_ENTS[ENEMY_NUM][] = {
	"monster_alien_controller",
	"monster_alien_grunt",
	"monster_alien_slave",
	"monster_apache",
	"monster_barnacle",
	"monster_babycrab",
	"monster_bigmomma",
	"monster_bullchicken",
	"monster_gargantua",
	"monster_headcrab",
	"monster_houndeye",
	"monster_human_assassin",
	"monster_human_grunt",
	"monster_ichthyosaur",
	//"monster_leech",
	"monster_miniturret",
	"monster_nihilanth",
	"monster_osprey",
	"monster_sentry",
	//"monster_snark",
	"monster_tentacle",
	"monster_turret",
	"monster_zombie"
};
new const ENEMY_NAMES[ENEMY_NUM][] = {
	"(Controller)",
	"(Alien Grunt)",
	"(Vortigaunt)",
	"(Apache)",
	"(Barnacle)",
	"(Baby Headcrab)",
	"(Gonarch)",
	"(Bullsquid)",
	"(Gargantua)",
	"(Headcrab)",
	"(Houndeye)",
	"(Assassin)",
	"(Grunt)",
	"(Ichthyosaur)",
	//"(Leech)",
	"(Mini Turret)",
	"(Nihilanth)",
	"(Osprey)",
	"(Sentry)",
	//"(Snark)",
	"(Tentacle)",
	"(Turret)",
	"(Zombie)"
};

// w/o comments: 8
#define W_CUSTOM_NUM 8
new const W_CUSTOM[W_CUSTOM_NUM][] = {
	"hvr_rocket",
	"hornet",
	"nihilanth_energy_ball",
	"controller_head_ball",
	"grenade",
	"garg_stomp",
	"squidspit",
	"bmortar"
};
new const W_ENTITY[W_CUSTOM_NUM][] = {
	"monster_apache",
	"monster_alien_grunt",
	"monster_nihilanth",
	"monster_alien_controller",
	"monster_human_grunt",
	"monster_gargantua",
	"monster_bullchicken",
	"monster_bigmomma"
};

// Globals //
new bool:gIsKilled[MAX_ENTS];
new bool:gRenameBusy;

new gBotID;
new gLastInflictor[MAX_PLAYERS + 1][32];
new gMsgSayText, gMsgScoreInfo, gMsgDeathMsg;

new Trie:gEnemyMap;

///////////////
// AMX FUNCS //
///////////////

public client_disconnect(id) {
	if (id == gBotID) CreateBot();
}

public client_infochanged(id) {
	if (!is_user_bot(id))
		VerifyNickname(TASK_VERIFYNICK + id);
}

// todo: is this needed? seems to rename immediately
public client_putinserver(id) {
	if (!is_user_bot(id))
		set_task( 10.0, "VerifyNickname", TASK_VERIFYNICK + id);
}

public plugin_init() {
	register_plugin(PLUGIN, VERSION, AUTHOR);
	
	register_forward(FM_GetGameDescription, "Forward_GameDesc");
	
	CreateBot();
	
	gMsgSayText = get_user_msgid("SayText");
	gMsgScoreInfo = get_user_msgid("ScoreInfo");
	gMsgDeathMsg = get_user_msgid("DeathMsg");
	
	gEnemyMap = TrieCreate();
	
	for (new i = 0; i < ENEMY_NUM; i++) {
		TrieSetString(gEnemyMap, ENEMY_ENTS[i], ENEMY_NAMES[i]);
		
		RegisterHam(Ham_TakeDamage, ENEMY_ENTS[i], "Enemy_HurtPre");
		RegisterHam(Ham_Killed, ENEMY_ENTS[i], "Enemy_KilledPost", 1 );
		RegisterHam(Ham_Spawn, ENEMY_ENTS[i], "Enemy_SpawnPost", 1);
	}
	
	// note: this will NOT be called for plugin-made deathmsgs
	// thus monsters suiciding are solely handled by Enemy_KilledPost
	register_message(gMsgDeathMsg, "Message_DeathMsg");
}

//////////////////////
// HOOKS + FORWARDS //
//////////////////////

public Enemy_HurtPre(victim, inflictor, attacker, Float:damage, bits)  {
	new Float:health;
	pev(victim, pev_health, health);
	
	// first used for victim check, then inflictor store, then victim check again
	new szClassname[32];
	pev(victim, pev_classname, szClassname, charsmax(szClassname));
	
	new bool:isTentacle = contain(szClassname, "tentacle") != -1;
	new bool:isNihilanth = contain(szClassname, "nihilanth") != -1;
	
	// check for last inflictor if damage is lethal
	// for tentacles, 1hp is "lethal"
	// for nihilanth, 0hp is lethal only if its m_irritation == 3
	if ((damage >= health && !isTentacle && !isNihilanth) ||
	      (isTentacle && damage >= (health - 1)) ||
	      (isNihilanth && damage >= health && get_pdata_int(victim, M_IRRITATION) == 3)) {
		if (inflictor == attacker && IS_PLAYER_ENT(attacker)) {
			new weapon = get_user_weapon(attacker);
			get_weaponname(weapon, szClassname, charsmax(szClassname));
		}
		else pev(inflictor, pev_classname, szClassname, charsmax(szClassname));
		
		// must do "weapon_" ones here because for RadiusDamage functions
		// inflictor != attacker (egon splash, gauss explosion, xbow hit)
		replace(szClassname, 31, "weapon_crossbow", "bolt");
		replace(szClassname, 31, "weapon_", "");
		replace(szClassname, 31, "func_", "");
		replace(szClassname, 31, "monster_", "");
		
		new i;
		if (attacker > 32) i = NO_ATTACKER;
		else i = attacker;
		
		copy(gLastInflictor[i], 31, szClassname);
		
		pev(victim, pev_classname, szClassname, charsmax(szClassname));
		
		if (contain(szClassname, "tentacle") != -1 && !task_exists(TASK_TENTACLE + victim)) {
			set_task(0.1, "Tentacle_CheckRespawn", TASK_TENTACLE + victim);
		}
		
		// hack: the following monsters do not trigger Ham_Killed
		if (contain(szClassname, "sentry") != -1 ||
		      contain(szClassname, "turret") != -1 ||
		      contain(szClassname, "tentacle") != -1 ||
		      contain(szClassname, "nihilanth") != -1)
			Enemy_KilledPost(victim, attacker);
	}
	
	return HAM_IGNORED;
}

public Enemy_KilledPost(victim, attacker) {
	// shooting monsters during their death animation kills them repeatedly
	if (gIsKilled[victim]) return;
	gIsKilled[victim] = true;
	
	// add frag to attacker if applicable
	if (IS_PLAYER_ENT(attacker)) {
		set_user_frags(attacker, get_user_frags(attacker) + 1);
		message_begin(MSG_ALL, gMsgScoreInfo);
		write_byte(attacker);
		write_short(get_user_frags(attacker));
		write_short(hl_get_user_deaths(attacker));
		write_short(0);
		write_short(hl_get_user_team(attacker));
		message_end();
	}
	
	// add death to monster bot
	hl_set_user_deaths(gBotID, hl_get_user_deaths(gBotID) + 1);
	message_begin(MSG_ALL, gMsgScoreInfo);
	write_byte(gBotID);
	write_short(get_user_frags(gBotID));
	write_short(hl_get_user_deaths(gBotID));
	write_short(0);
	write_short(hl_get_user_team(gBotID));
	message_end();
		
	new szClassname[32];
	pev(victim, pev_classname, szClassname, charsmax(szClassname));
	
	// 0 - 31: enemy name
	// 32: attacker id
	new args[33];
	
	TrieGetString(gEnemyMap, szClassname, args, 31);
	args[32] = IS_PLAYER_ENT(attacker)? attacker : NO_ATTACKER;
		
	set_task(0.1, "Task_Rename1", TASK_RENAME1, args, 33);
}

public Enemy_SpawnPost(ent) {
	// reset monster killed check
	gIsKilled[ent] = false;
}

// game mode name that should be displayed in server browser
public Forward_GameDesc() {
	new szGameDesc[32];
	formatex(szGameDesc, 31, "%s %s", PLUGIN, VERSION);
	forward_return(FMV_STRING, szGameDesc);
	return FMRES_SUPERCEDE;
}

public Message_DeathMsg(msgId, msgDest, msgEnt) {
	// for monsters, attacker is always 0
	new attacker = get_msg_arg_int(1);
	if (attacker != 0) return PLUGIN_CONTINUE;
	
	new victim = get_msg_arg_int(2);
	
	new szWeapon[32];
	get_msg_arg_string(3, szWeapon, charsmax(szWeapon));
	
	new i;
	
	// specific per-monster weapons (like "hvr_rocket" for monster_apache)
	for (i = 0; i < W_CUSTOM_NUM; i++) {
		if (contain(szWeapon, W_CUSTOM[i]) != -1) {
			MonsterDidKill(victim, szWeapon, W_ENTITY[i]);
			
			// still need to rename, so we're blocking this deathmsg and making our own
			return PLUGIN_HANDLED;
		}
	}
	
	// generic weapon (like "zombie" for monster_zombie)
	for (i = 0; i < ENEMY_NUM; i++) {
		new szMonster[32];
		copy(szMonster, charsmax(szMonster), ENEMY_ENTS[i]);
		replace(szMonster, 31, "monster_", "");
	
		if (contain(szWeapon, szMonster) != -1) {
			MonsterDidKill(victim, szWeapon, ENEMY_ENTS[i]);
			
			return PLUGIN_HANDLED;
		}
	}
	
	return PLUGIN_CONTINUE;
}

////////////////
// MISC FUNCS //
////////////////

// bot for custom deathmsgs, as well as keeping track of kills/deaths in the scoreboard
public CreateBot() {
	new bot = engfunc(EngFunc_CreateFakeClient, ENEMY_BOT);
	if (bot == 0)
		set_fail_state("Failed to create fake client");

	// prevents crashes?
	dllfunc(MetaFunc_CallGameEntity, "player", bot);
	set_pev(bot, pev_flags, FL_FAKECLIENT);

	// make sure we're invisible
	set_pev(bot, pev_model, "");
	set_pev(bot, pev_viewmodel2, "");
	set_pev(bot, pev_modelindex, 0);
	set_pev(bot, pev_renderfx, kRenderFxNone);
	set_pev(bot, pev_rendermode, kRenderTransAlpha);
	set_pev(bot, pev_renderamt, 0.0);

	gBotID = get_user_index(ENEMY_BOT);
}

public MonsterDidKill(victim, szWeapon[], szClassname[]) {
	// add frag to monster bot
	set_user_frags(gBotID, get_user_frags(gBotID) + 1);
	message_begin(MSG_ALL, gMsgScoreInfo);
	write_byte(gBotID);
	write_short(get_user_frags(gBotID));
	write_short(hl_get_user_deaths(gBotID));
	write_short(0);
	write_short(hl_get_user_team(gBotID));
	message_end();
	
	// 0 - 31: enemy name
	// 32: victim id
	new args[33];

	TrieGetString(gEnemyMap, szClassname, args, 31);
	args[32] = victim + 33;
	copy(gLastInflictor[victim], 31, szWeapon);

	set_task(0.1, "Task_Rename1", TASK_RENAME1, args, 33);
}

///////////
// TASKS //
///////////

// hack: briefly rename the bot to the monster we just killed (or that killed us) so it shows up in the deathmsg
public Task_Rename1(args[]) {
	// loop until we're not busy anymore
	if (gRenameBusy) {
		set_task(0.1, "Task_Rename1", TASK_RENAME1, args, 33);
		return;
	}
	gRenameBusy = true;
	
	new szName[32];
	copy(szName, 31, args);
	
	// ids 1 - 32: player is attacker
	// ids 34 - 65: player is victim
	new id = args[32] % 33;
	
	// player d/c'd, skip rename procedure
	if (!is_user_connected(id)) {
		gRenameBusy = false;
		return;
	}
	
	// silently rename the bot
	set_msg_block(gMsgSayText, BLOCK_ONCE);
	set_user_info(gBotID, "name", szName);
	
	// allow short delay for rename to take effect
	set_task(0.1, "Task_Rename2", TASK_RENAME2 + args[32]);
}

public Task_Rename2(arg) {
	arg -= TASK_RENAME2;
	new id = arg % 33;
	
	// make sure player hasn't d/c'd
	if (is_user_connected(id))
	{
		// player is victim
		if (arg > 32) {
			message_begin(MSG_ALL, gMsgDeathMsg, {0,0,0}, 0);
			write_byte(gBotID);
			write_byte(id);
			write_string(gLastInflictor[id]);
			message_end();
		}
		
		// player is attacker
		else {
			message_begin(MSG_ALL, gMsgDeathMsg, {0,0,0}, 0);
			write_byte(id);
			write_byte(gBotID);
			write_string(gLastInflictor[id]);
			message_end();
		}
	}
	
	// silently rename back
	set_msg_block(gMsgSayText, BLOCK_ONCE);
	set_user_info(gBotID, "name", ENEMY_BOT);
	
	gRenameBusy = false;
}

public Tentacle_CheckRespawn(ent) {
	ent -= TASK_TENTACLE;
	
	// todo: is sequence check necessary?
	new sequence;
	pev(ent, pev_sequence, sequence);
	new Float:health;
	pev(ent, pev_health, health);
	
	// tentacle has respawned if sequence is TENTACLE_ANIM_Pit_Idle (0) AND health is over 1 (default 75)
	// timer should be >99% precise enough, if not then i'll have to switch to Ham_Think or smth
	if (sequence != 0 || health < 1.1) {
		set_task(0.1, "Tentacle_CheckRespawn", TASK_TENTACLE + ent);
		return;
	}
	
	gIsKilled[ent] = false;
}

// not to cause confusion or break the bot, block players from containing certain phrases in names
public VerifyNickname(id) {
	id -= TASK_VERIFYNICK;
	
	new szName[32];
	get_user_info(id, "name", szName, charsmax(szName));
	
	if (contain(szName, ENEMY_BOT) != -1) {
		client_print(id, print_chat, "Sorry, you can't have '%s' in your nickname.", ENEMY_BOT);
		
		replace(szName, 31, ENEMY_BOT, "");
		set_user_info(id, "name", szName);
	}
	
	for (new i = 0; i < ENEMY_NUM; i++) {
		if (contain(szName, ENEMY_NAMES[i]) != -1) {
			client_print(id, print_chat, "Sorry, you can't have '%s' in your nickname.", ENEMY_NAMES[i]);
			
			replace(szName, 31, ENEMY_NAMES[i], "");
			set_user_info(id, "name", szName);
		}
	}
}
/* AMXX-Studio Notes - DO NOT MODIFY BELOW HERE
*{\\ rtf1\\ ansi\\ deff0{\\ fonttbl{\\ f0\\ fnil Tahoma;}}\n\\ viewkind4\\ uc1\\ pard\\ lang1033\\ f0\\ fs16 \n\\ par }
*/
