#include <sourcemod>
#include <cstrike>
#include <sdktools>
#include <clientprefs>

#define PLUGIN_VERSION		"1.1-RC"

#define MISSION_COMPLETE	"music/thinice_success.mp3"
#define MISSION_FAILED		"music/train_failure.mp3"
#define TASK_COMPLETED		"events/task_complete.wav"

#define CAMPAIGN_CONFIG		"condition_zero"

public Plugin myinfo = 
{
	name = "Condition Zero Source",
	author = "MuLLlaH9!",
	description = "Task-tracking gameplay port from Counter-Strike: Condition Zero",
	version = PLUGIN_VERSION,
	url = "https://github.com/MuxaJlbl4/Condition-Zero-Source"
};

enum struct AchievementTask
{
	char TaskType[32];
	int TargetValue;
	char Weapon[32];
	bool RequireHeadshot;
	bool WithoutDying;
	bool RequireSurvival;
	bool RequireNoReload;
	int CurrentProgress;
	bool Completed;
}

float g_RoundStartTime;
bool g_bBlinded[MAXPLAYERS+1], g_bUseOriginalAutobuy;
int g_TotalHostages, g_HostagesRescuedThisRound;
int g_iLastClip[MAXPLAYERS+1];
ArrayList g_Tasks, g_hFollowedHostages, g_UsedWeapons;
ConVar g_cvHumanTeam, g_cvMatchwins, g_cvMatchwinsby, g_cvFreezeTime, g_cvBotDifficulty, g_cvTeamChosen, g_cvSimpleCoop, g_cvHostname, g_cvTeammates, g_cvOpponents, g_cvBotsPerPlayer, g_cvBotQuota, g_cvCheats;

public OnPluginStart()
{
	// Existing hooks and commands
	g_cvTeammates = CreateConVar("cz_teammates", "0", "Number of teammate bots");
	g_cvOpponents = CreateConVar("cz_opponents", "0", "Number of enemy bots");
	g_cvBotsPerPlayer = CreateConVar("cz_bots_per_player", "1", "Extra bots for each joined player");
	g_cvMatchwins = CreateConVar("cz_matchwins", "3", "The minimum number of rounds a team must win in order to win a match");
	g_cvMatchwinsby = CreateConVar("cz_matchwinsby", "2", "The number of wins a team must lead by in order to win a match");
	g_cvTeamChosen = CreateConVar("cz_teamchosen", "0", "Is team and difficulty already chosen for this session");
	g_cvSimpleCoop = CreateConVar("cz_simple_coop", "1", "Simplified survival and in-a-row tasks for coop");
	g_cvHumanTeam = FindConVar("mp_humanteam");
	g_cvFreezeTime = FindConVar("mp_freezetime");
	g_cvHostname = FindConVar("hostname"); // Used for campaign name transmission from BonusMapDialog
	g_cvBotDifficulty = FindConVar("bot_difficulty");
	g_cvBotQuota = FindConVar("bot_quota");
	g_cvCheats = FindConVar("sv_cheats");
	
	// Restrict "any" value for mp_humanteam
	if (IsHumanTeamAny())
		ServerCommand("mp_humanteam CT");
	
	g_Tasks = new ArrayList(sizeof(AchievementTask));
	g_hFollowedHostages = new ArrayList();	
	g_UsedWeapons = new ArrayList(32);
	ResetWeapons();
	
	RegConsoleCmd("cz_task_add", Command_AddTask, "Add a new task");
	RegConsoleCmd("cz_task_delete", Command_DeleteAllTasks, "Delete all tasks");
	RegConsoleCmd("cz_task_reset", Command_ResetAllProgress, "Reset all task progress");
	
	RegConsoleCmd("cz_list", Command_ListTasks, "List all active achievement tasks");
	
	RegConsoleCmd("cz_skip", Command_NextRound, "Forces round end with opposite team win");
	
	RegConsoleCmd("cz_victory", Command_Victory, "Force match victory", ADMFLAG_CHEATS);
	RegConsoleCmd("cz_defeat", Command_Defeat, "Force match defeat");
	
	RegConsoleCmd("autobuy", Command_Autobuy);
	
	CreateConVar("cz_version", PLUGIN_VERSION, "Current Version", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY);
	
	// Hook game events
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_hurt", Event_PlayerHurt);
	HookEvent("round_end", Event_RoundEnd);
	HookEvent("round_start", Event_RoundStart);
	HookEvent("player_blind", Event_PlayerBlind);
	HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
	HookEvent("weapon_reload", Event_WeaponReload);
	HookEvent("bomb_planted", Event_BombPlanted);
	HookEvent("bomb_defused", Event_BombDefused);
	AddTempEntHook("Player Decal", PlayerSpray);
	
	// Hook hostage following
	HookEvent("hostage_rescued", Event_HostageRescued);
	HookEvent("hostage_follows", Event_HostageFollows);
	HookEvent("hostage_stops_following", Event_HostageStopsFollowing);
	HookEvent("hostage_killed", Event_HostageKilled);
	
	// Hook cVar change
	HookConVarChange(g_cvBotDifficulty, OnDifficultyChanged);
	HookConVarChange(g_cvHumanTeam, OnHumanTeamChanged);
	
	// Hook VGUI
	HookUserMessage(GetUserMessageId("VGUIMenu"), VGUIMenu, true);

	// Reset team and difficulty chose for random missions
	if (IsRandomMission())
		g_cvTeamChosen.IntValue = 0;
}

// Player joined team
public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
		
	if (!IsValidClient(client) || IsFakeClient(client))
			return;
	
	// First player (admin) joined team, initialise bots and tasks
	if (client == 1)
	{		
		int oldTeam = event.GetInt("oldteam");
		int newTeam = event.GetInt("team");
		bool disconnect = event.GetBool("disconnect");

		// Check if joined to playable team
		if (!disconnect && (newTeam == CS_TEAM_CT || newTeam == CS_TEAM_T))
		{
			// Verify transition from non-playable team
			if (oldTeam < CS_TEAM_CT || oldTeam == CS_TEAM_SPECTATOR)
			{			
				// Get map name
				new String:currentMap[PLATFORM_MAX_PATH];
				GetCurrentMap(currentMap, sizeof(currentMap));
				
				// Get campaign name
				new String:currentCampaign[PLATFORM_MAX_PATH];
				g_cvHostname.GetString(currentCampaign, sizeof(currentCampaign));
				
				// Execute mission config
				if (IsRandomMission())
					SetRandomMission();
				else
					ServerCommand("exec %s/%s.cfg", currentCampaign, currentMap);
				
				// Add bots according config
				CreateTimer(0.1, Timer_SafeInitBotTeams);
				
				// Reset used weapons
				ResetWeapons();
			}
		}
	}
	// Check extra bots on player join
	else if (IsClientInGame(1))
		CreateTimer(1.0, Timer_SafeAddExtraBot);
}

bool IsRandomMission()
{
	// Get campaign name
	new String:currentCampaign[PLATFORM_MAX_PATH];
	g_cvHostname.GetString(currentCampaign, sizeof(currentCampaign));
	return StrContains(currentCampaign, " Server") != -1;
}

public void SetRandomMission()
{
	// Init Bots
	g_cvBotQuota.IntValue = 0;
	
	int opponents = GetRandomInt(3, 10);
	g_cvOpponents.IntValue = opponents;
	g_cvTeammates.IntValue = opponents - GetRandomInt(1, 3);
	
	// Define task lists
	static const char s_TaskListFirst[][64] =
	{
		"kill 10",
		"kill 5 inarow",
		"kill 3 survive",
		"killwith 2 pistol",
		"killwith 2 shotgun",
		"killwith 2 smg",
		"killwith 3 sniper",
		"killwith 3 rifle",
		"killwith 3 machinegun"
	};

	static const char s_TaskListSecond[][64] =
	{
		"killwith 1 deagle survive",
		"killwith 1 scout survive",
		"killwith 3 sg550 inarow",
		"killwith 2 awp survive",
		"killwith 1 p90 survive",
		"killwith 3 m4a1 inarow",
		"killwith 2 aug survive",
		"killwith 3 m249 inarow"
	};

	static const char s_TaskListThird[][64] =
	{
		"spray 3",
		"winfast 60",
		"killwith 1 knife",
		"killblind 1",
		"killwith 1 hegrenade",
		"killvary 3 survive",
		"killvary 5 inarow"
	};
	
	// Get map name
	new String:currentMap[PLATFORM_MAX_PATH];
	GetCurrentMap(currentMap, sizeof(currentMap));
	
	// Add random tasks
	if ((currentMap[0] == 'c' && currentMap[1] == 's' && currentMap[2] == '_') || (currentMap[0] == 'd' && currentMap[1] == 'e' && currentMap[2] == '_'))
	{
		AddRandomTask(s_TaskListFirst, sizeof(s_TaskListFirst));
		AddRandomTask(s_TaskListSecond, sizeof(s_TaskListSecond));
		AddRandomTask(s_TaskListThird, sizeof(s_TaskListThird));
	}
	else
	{
		AddRandomTask(s_TaskListFirst, 3);
		AddRandomTask(s_TaskListThird, 3);
	}
	
	return;
}

void AddRandomTask(const char[][] tasks, int size)
{
	char task[64];
	strcopy(task, sizeof(task), tasks[GetRandomInt(0, size-1)]);
	ServerCommand("cz_task_add %s", task);
}

void InitBotTeams()
{
	for (int i = 0; i < g_cvTeammates.IntValue; i++)
		ServerCommand("bot_add_%s", IsHumanTeamCT() ? "ct" : "t");
	
	for (int i = 0; i < g_cvOpponents.IntValue; i++)
		ServerCommand("bot_add_%s", IsHumanTeamCT() ? "t" : "ct");
}

public Action:VGUIMenu(UserMsg:msg_id, Handle:bf, const players[], playersNum, bool:reliable, bool:init)
{
	new String:buffer[5];
	BfReadString(bf, buffer, sizeof(buffer));
	// Skip MotD
	if (StrEqual(buffer, "info"))
		return Plugin_Handled;
	// Skip Team and Difficulty Window
	if (StrEqual(buffer, "clas") || StrEqual(buffer, "team"))
		if (g_cvTeamChosen.IntValue == 1 && !IsHumanTeamAny())
			return Plugin_Handled;
	
	return Plugin_Continue;
}

public void OnDifficultyChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	// If difficulty was changed during started game, reload level
	if (g_cvTeamChosen.IntValue == 1)
		CreateTimer(0.1, Timer_SafeRestartLevel);
}

public void OnHumanTeamChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	// If human team was changed during started game, reload level
	if (g_cvTeamChosen.IntValue == 1)
		CreateTimer(0.1, Timer_SafeRestartLevel);
}

public void OnClientPutInServer(int client)
{
	if (!IsValidClient(client))
		return;
	
	if (g_cvTeamChosen.IntValue == 1 && !IsHumanTeamAny())
		ClientCommand(client, "jointeam 0; joinclass 0")
	else
		CreateTimer(0.1, timer_menu, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action:timer_menu(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (client != 0 && !IsFakeClient(client))
	{
		ClientCommand(client, "hidepanel specgui") // Hide spectator bars
		ShowVGUIPanel(client, "team", INVALID_HANDLE, true); // Select team menu
	}
}

public void OnMapStart()
{
	// Sounds init
	PrecacheSound(MISSION_COMPLETE, true);
	PrecacheSound(MISSION_FAILED, true);
	PrecacheSound(TASK_COMPLETED, true);
	
	AddFileToDownloadsTable("sound/music/thinice_success.mp3");
	AddFileToDownloadsTable("sound/music/train_failure.mp3");
	AddFileToDownloadsTable("sound/events/task_complete.wav");
	
	// Delete old tasks
	Command_DeleteAllTasks(0, 0);
	
	// Auto reload tracking:
	static Handle s_hClipTimer;
	if (s_hClipTimer != null)
		KillTimer(s_hClipTimer);
	s_hClipTimer = CreateTimer(1.0, Timer_CheckClip, _, TIMER_REPEAT);
}

static bool File_Copy(const char[] source, const char[] destination)
{
	File file_source = OpenFile(source, "rb");

	if (file_source == null)
	{
		return false;
	}

	File file_destination = OpenFile(destination, "wb");

	if (file_destination == null)
	{
		delete file_source;

		return false;
	}

	int[] buffer = new int[32];
	int cache = 0;

	while (!IsEndOfFile(file_source))
	{
		cache = ReadFile(file_source, buffer, 32, 1);

		file_destination.Write(buffer, cache, 1);
	}

	delete file_source;
	delete file_destination;

	return true;
} 

public OnConfigsExecuted()
{
	// Clear previous bots
	g_cvBotQuota.IntValue = 0;
	
	// Get map name
	new String:currentMap[PLATFORM_MAX_PATH];
	GetCurrentMap(currentMap, sizeof(currentMap));
	
	// Get campaign name
	new String:currentCampaign[PLATFORM_MAX_PATH];
	g_cvHostname.GetString(currentCampaign, sizeof(currentCampaign));
	
	// Check current botprofile.db and mapcycle.txt
	char configPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, configPath, sizeof(configPath), "../../cfg/current_campaign.cfg", CAMPAIGN_CONFIG);
	
	// Check file availability
	File file = OpenFile(configPath, "r");
	if (file == null)
	{
		// Create new config with current campaign
		file = OpenFile(configPath, "w");
		if (file != null)
		{
			file.WriteLine(currentCampaign);
			file.Close();
			UpdateCampaignFiles(currentCampaign);
		}
		return;
	}
	
	char savedCampaign[PLATFORM_MAX_PATH];
	bool campaignFound = false;
	
	while(!file.EndOfFile() && !campaignFound)
	{
		if (file.ReadLine(savedCampaign, sizeof(savedCampaign)))
		{
			TrimString(savedCampaign);
			if (savedCampaign[0] != '\0' && savedCampaign[0] != '/')
			{
				campaignFound = true;
			}
		}
	}
	file.Close();
	
	// Compare campaigns with case sensitivity
	if (!StrEqual(savedCampaign, currentCampaign, false))
	{
		// Update config file
		File newFile = OpenFile(configPath, "w");
		if (newFile != null)
		{
			newFile.WriteLine(currentCampaign);
			newFile.Close();
		}
		UpdateCampaignFiles(currentCampaign);
	}
	
	// Execute game config
	ServerCommand("exec game.cfg");
	
	// Execute campaign config
	ServerCommand("exec %s/campaign.cfg", currentCampaign);
	
	// Kind of a hack: force nextmap updating for campaigns, according to custom mapcycle.txt
	ServerCommand("sm_nextmap \"\"");
}

public void UpdateCampaignFiles(const char[] currentCampaign)
{
	// Kind of a hack for custom campaigns: replace some uncontrolled with SourceMod files and restart server
	
	// File replacement
	char srcPath[PLATFORM_MAX_PATH];
	char destPath[PLATFORM_MAX_PATH];
	
	// Check current configs for current campaign
	if (!IsRandomMission())
		BuildPath(Path_SM, srcPath, sizeof(srcPath), "../../custom/%s/cfg/%s/botprofile.db", currentCampaign, currentCampaign);
	else
		BuildPath(Path_SM, srcPath, sizeof(srcPath), "../../custom/%s/vanilla/botprofile.db", CAMPAIGN_CONFIG);
	BuildPath(Path_SM, destPath, sizeof(destPath), "../../custom/%s/botprofile.db", CAMPAIGN_CONFIG);
	File_Copy(srcPath, destPath);
	
	// Replace mapcycle
	if (!IsRandomMission())
		BuildPath(Path_SM, srcPath, sizeof(srcPath), "../../custom/%s/cfg/%s/mapcycle.txt", currentCampaign, currentCampaign);
	else
		BuildPath(Path_SM, srcPath, sizeof(srcPath), "../../cfg/mapcycle_default.txt", CAMPAIGN_CONFIG);
	BuildPath(Path_SM, destPath, sizeof(destPath), "../../cfg/mapcycle.txt", CAMPAIGN_CONFIG);
	File_Copy(srcPath, destPath);

	// Delay campaign change to prevent infinite loops
	CreateTimer(0.1, Timer_SafeCampaignChange);
}

public Action Timer_SafeCampaignChange(Handle timer)
{
	// Reset campaign difficulty
	g_cvTeamChosen.IntValue = 0;
	
	ReloadLevel();

	return Plugin_Stop;
}

public Action Timer_SafeRestartLevel(Handle timer)
{
	ReloadLevel();

	return Plugin_Stop;
}

public Action Timer_SafeInitBotTeams(Handle timer)
{
	InitBotTeams();

	return Plugin_Continue;
}

public Action Timer_SafeAddExtraBot(Handle timer)
{
	if (CountRealPlayers() < 2)
		return Plugin_Continue;
	
	int extraOpponents = (CountRealPlayers() - 1) * g_cvBotsPerPlayer.IntValue
	
	if (CountEnemyTeam() < g_cvOpponents.IntValue + extraOpponents)
	{
		ServerCommand("bot_add_%s", IsHumanTeamCT() ? "t" : "ct");
		CreateTimer(1.0, Timer_SafeAddExtraBot);
	}
	return Plugin_Continue;
}

public void ReloadLevel()
{
	// Get map name (Campaign_Name/map_name)
	new String:currentMap[PLATFORM_MAX_PATH];
	GetCurrentMap(currentMap, sizeof(currentMap));
	
	ServerCommand("changelevel %s", currentMap);
}

public Action CS_OnTerminateRound(float &delay, CSRoundEndReason &reason)
{
	CheckVictory(true);
}

public void CheckVictory(bool prepare)
{
	// Check team score
	int ct_wins = CS_GetTeamScore(CS_TEAM_CT);
	int t_wins = CS_GetTeamScore(CS_TEAM_T);
	int wins_by = ct_wins - t_wins;
	int wins = ct_wins + t_wins;
	
	if (wins >= g_cvMatchwins.IntValue)
	{	
		if (wins_by >= g_cvMatchwinsby.IntValue)
		{
			if (IsHumanTeamCT())
			{
				if (AllTasksCompleted())
				{
					// Game won by human team CT
					if (prepare)
						PrepareMissionCompletion();
					else
						MissionCompleted();
				}
			}
			else
			{
				// Game fail by human team T
				MissionFailed();
			}
		}
		if (wins_by <= -g_cvMatchwinsby.IntValue)
		{
			if (IsHumanTeamCT())
			{
				// Game fail by human team CT
				MissionFailed();
			}
			else if (AllTasksCompleted())
			{
				// Game won by human team T
				if (prepare)
					PrepareMissionCompletion();
				else
					MissionCompleted();
			}
		}
	}
}

public void MissionFailed()
{
	// Restart and reset tasks
	EmitSoundToAllPlayers(MISSION_FAILED);
	ServerCommand("mp_restartgame 10");
	Command_ResetAllProgress(0, 0);
}

public void MissionCompleted()
{
	// Show scoreboard and proceed to next map
	new iGameEnd = FindEntityByClassname(-1, "game_end");
	if (iGameEnd == -1 && (iGameEnd = CreateEntityByName("game_end")) == -1)
		LogError("Unable to create entity \"game_end\"!");
	else
		AcceptEntityInput(iGameEnd, "EndGame");
	
	// Remove all weapons for players
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i) && !IsFakeClient(i))
		{
			new iEnt;
			for (new j = 0; j <= 4; j++)
			{
				while ((iEnt = GetPlayerWeaponSlot(i, j)) != -1)
				{
					RemovePlayerItem(i, iEnt);
					AcceptEntityInput(iEnt, "Kill");
				}
			}
		}
	}
	
	EmitSoundToAllPlayers(MISSION_COMPLETE);
}

public void PrepareMissionCompletion()
{
	CreateTimer(2.5, Timer_DelayedMissionCompleted);
}

public void Timer_DelayedMissionCompleted(Handle:timer)
{
	MissionCompleted();
}

public void EmitSoundToAllPlayers(const char[] sound)
{
	// Show task list for all players in the chat
	for (int i = 1; i <= MaxClients; i++)
		if (IsValidClient(i))
			EmitSoundToClient(i, sound);
}

public bool IsHumanTeamCT()
{
	char team[8];
	g_cvHumanTeam.GetString(team, sizeof(team));
	return StrEqual(team, "CT", false);
}

bool IsHumanTeamT()
{
	char team[8];
	g_cvHumanTeam.GetString(team, sizeof(team));
	return StrEqual(team, "T", false);
}

bool IsHumanTeamAny()
{
	char team[8];
	g_cvHumanTeam.GetString(team, sizeof(team));
	return StrEqual(team, "any", false);
}

public Action Command_AddTask(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "Usage: cz_task_add <type> [arguments]");
		return Plugin_Handled;
	}

	char type[32], buffer[256];
	GetCmdArg(1, type, sizeof(type));
	GetCmdArgString(buffer, sizeof(buffer));
	
	// Argument validation per task type
	if (StrEqual(type, "kill") && args < 2)
		ReplyToCommand(client, "Usage: cz_task_add kill <target> [headshot] [inarow] [survive] [noreload]");
	else if (StrEqual(type, "killwith") && args < 3)
		ReplyToCommand(client, "Usage: cz_task_add killwith <target> <weapon> [headshot] [inarow] [survive] [noreload]");
	else if (StrEqual(type, "killblind") && args < 2)
		ReplyToCommand(client, "Usage: cz_task_add killblind <target> [headshot] [inarow] [survive] [noreload]");
	else if (StrEqual(type, "killsilent") && args < 2)
		ReplyToCommand(client, "Usage: cz_task_add killsilent <target> [headshot] [inarow] [survive] [noreload]");
	else if (StrEqual(type, "killnoscope") && args < 2)
		ReplyToCommand(client, "Usage: cz_task_add killnoscope <target> [headshot] [inarow] [survive] [noreload]");
	else if (StrEqual(type, "killjump") && args < 2)
		ReplyToCommand(client, "Usage: cz_task_add killjump <target> [headshot] [inarow] [survive] [noreload]");
	else if (StrEqual(type, "killvary") && args < 2)
		ReplyToCommand(client, "Usage: cz_task_add killvary <target> [headshot] [inarow] [survive] [noreload]");
	else if (StrEqual(type, "killtrophy") && args < 2)
		ReplyToCommand(client, "Usage: cz_task_add killtrophy <target> [headshot] [inarow] [survive] [noreload]");
	else if (StrEqual(type, "damage") && args < 2)
		ReplyToCommand(client, "Usage: cz_task_add damage <target> [headshot] [inarow] [survive] [noreload]");
	else if (StrEqual(type, "damagewith") && args < 3)
		ReplyToCommand(client, "Usage: cz_task_add damagewith <target> <weapon> [headshot] [inarow] [survive] [noreload]");
	else if (StrEqual(type, "winfast") && args < 2)
		ReplyToCommand(client, "Usage: cz_task_add winfast <target> [survive]");
	else if (StrEqual(type, "rescue") && args < 2)
		ReplyToCommand(client, "Usage: cz_task_add rescue <target>");
	else if (StrEqual(type, "spray") && args < 2)
		ReplyToCommand(client, "Usage: cz_task_add spray <target>");
	else if (StrEqual(type, "rescueall") && args != 1)
		ReplyToCommand(client, "Usage: cz_task_add rescueall");
	else if (StrEqual(type, "bomb") && args != 1)
		ReplyToCommand(client, "Usage: cz_task_add bomb");
	else
	{
		// Parse and add the task
		AchievementTask task;
		strcopy(task.TaskType, sizeof(task.TaskType), type);
		
		if (StrEqual(type, "kill") ||
		StrEqual(type, "killblind") ||
		StrEqual(type, "killsilent") ||
		StrEqual(type, "killnoscope") ||
		StrEqual(type, "killjump") || 
		StrEqual(type, "killvary") || 
		StrEqual(type, "killtrophy") || 
		StrEqual(type, "damage"))
		{
			task.TargetValue     = ParseTargetValue(buffer);
			task.RequireHeadshot = StrContains(buffer, "headshot") != -1;
			task.WithoutDying    = StrContains(buffer, "inarow")   != -1;
			task.RequireSurvival = StrContains(buffer, "survive")  != -1;
			task.RequireNoReload = StrContains(buffer, "noreload") != -1;
		}
		// killwith
		else if (StrEqual(type, "killwith") ||
		StrEqual(type, "damagewith"))
		{
			task.TargetValue = ParseTargetValue(buffer);
			ParseWeapon(buffer, task.Weapon, sizeof(task.Weapon));
			if (!IsValidWeaponArg(task.Weapon))
			{
				ReplyToCommand(client, "Unknown or unsupported weapon type. Available weapons: glock, usp, p228, deagle, elite, fiveseven, m3, xm1014, galil, ak47, scout, sg552, awp, g3sg1, famas, m4a1, aug, sg550, mac10, tmp, mp5navy, ump45, p90, m249, hegrenade, knife. Available weapons classes: pistol, shotgun, smg, rifle, sniper, machinegun");
				return Plugin_Handled;
			}
			task.RequireHeadshot = StrContains(buffer, "headshot") != -1;
			task.WithoutDying    = StrContains(buffer, "inarow")   != -1;
			task.RequireSurvival = StrContains(buffer, "survive")  != -1;
			task.RequireNoReload = StrContains(buffer, "noreload") != -1;
			if (StrEqual(task.Weapon, "knife", false) || StrEqual(task.Weapon, "hegrenade", false))
				task.RequireHeadshot = false;
		}
		else if (StrEqual(type, "winfast"))
		{
			task.TargetValue     = ParseTargetValue(buffer);
			task.RequireSurvival = StrContains(buffer, "survive") != -1;
		}
		else if (StrEqual(type, "rescue"))
		{
			if (IsHumanTeamT())
			{
				ReplyToCommand(client, "Rescue tasks are not available for T team");
				return Plugin_Handled;
			}
			task.TargetValue = ParseTargetValue(buffer);
		}
		else if (StrEqual(type, "rescueall"))
		{
			if (IsHumanTeamT())
			{
				ReplyToCommand(client, "Rescue tasks are not available for T team");
				return Plugin_Handled;
			}
		}
		else if (StrEqual(type, "spray"))
		{
			task.TargetValue = ParseTargetValue(buffer);
		}
		else if (StrEqual(type, "bomb"))
		{
			task.TargetValue = 0;
		}
		else
		{
			ReplyToCommand(client, "Unknown task type. Available types: kill, killwith, killblind, killsilent, killnoscope, killjump, killvary, damage, damagewith, winfast, rescue, rescueall, spray, bomb");
			return Plugin_Handled;
		}
		
		// Create task		
		g_Tasks.PushArray(task, sizeof(task));
		ReplyToCommand(client, "Task added: %s", buffer);
	}
	
	return Plugin_Handled;
}

bool IsValidWeaponArg(const char[] weapon)
{
	return  StrEqual(weapon, "glock")      || StrEqual(weapon, "usp")       ||
	        StrEqual(weapon, "p228")       || StrEqual(weapon, "deagle")     ||
	        StrEqual(weapon, "elite")      || StrEqual(weapon, "fiveseven")  ||
	        StrEqual(weapon, "m3")         || StrEqual(weapon, "xm1014")     ||
	        StrEqual(weapon, "galil")      || StrEqual(weapon, "ak47")       ||
	        StrEqual(weapon, "scout")      || StrEqual(weapon, "sg552")      ||
	        StrEqual(weapon, "awp")        || StrEqual(weapon, "g3sg1")      ||
	        StrEqual(weapon, "famas")      || StrEqual(weapon, "m4a1")       ||
	        StrEqual(weapon, "aug")        || StrEqual(weapon, "sg550")      ||
	        StrEqual(weapon, "mac10")      || StrEqual(weapon, "tmp")        ||
	        StrEqual(weapon, "mp5navy")    || StrEqual(weapon, "ump45")      ||
	        StrEqual(weapon, "p90")        || StrEqual(weapon, "m249")       ||
	        StrEqual(weapon, "hegrenade")  || StrEqual(weapon, "knife")      ||
	        StrEqual(weapon, "pistol")     || StrEqual(weapon, "shotgun")    ||
	        StrEqual(weapon, "smg")        || StrEqual(weapon, "rifle")      ||
	        StrEqual(weapon, "sniper")     || StrEqual(weapon, "machinegun");
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	int victim = GetClientOfUserId(event.GetInt("userid"));

	// If Player is victim
	if (IsValidClient(victim))
	{
		// Reset survival / inarow tasks on player death
		for (int i = 0; i < g_Tasks.Length; i++)
		{
			AchievementTask task;
			g_Tasks.GetArray(i, task, sizeof(task));
			
			if (task.RequireSurvival && !task.Completed)
			{
				if (g_cvSimpleCoop.IntValue && CountAlivePlayers() > 0)
					return;
				task.CurrentProgress = 0;
				g_Tasks.SetArray(i, task, sizeof(task));
				ResetWeapons();
			}
			
			if (task.WithoutDying && !task.Completed)
			{
				if (g_cvSimpleCoop.IntValue && CountAlivePlayers() > 0)
					return;
				task.CurrentProgress = 0;
				g_Tasks.SetArray(i, task, sizeof(task));
				ResetWeapons();
			}
		}
		return;
	}
	
	// If Player is attacker
	if (IsValidClient(attacker))
	{
		// Skip invalid or team kills
		if (GetClientTeam(attacker) == GetClientTeam(victim))
			return;
		
		char weapon[32];
		event.GetString("weapon", weapon, sizeof(weapon));
		
		bool isHeadshot = event.GetBool("headshot");
		
		// Iterate through all tasks
		for (int i = 0; i < g_Tasks.Length; i++)
		{
			AchievementTask task;
			g_Tasks.GetArray(i, task, sizeof(task));
			
			if (!task.Completed)
			{
				bool taskUpdated = false;
				// Skip if no headshot, when necessary
				if (task.RequireHeadshot)
					if (!isHeadshot)
						continue;
				
				// Update kill count
				if (StrEqual(task.TaskType, "kill"))
				{
					task.CurrentProgress++;
					taskUpdated = true;
				}
				else if (StrEqual(task.TaskType, "killwith"))
				{
					if (IsWeaponClass(task.Weapon))
					{
						if (IsWeaponClassValid(weapon, task.Weapon))
						{
							task.CurrentProgress++;
							taskUpdated = true;
						}
					}
					else if (StrEqual(weapon, task.Weapon))
					{
						task.CurrentProgress++;
						taskUpdated = true;
					}
				}	
				else if (StrEqual(task.TaskType, "killblind") && g_bBlinded[victim])
				{
					task.CurrentProgress++;
					taskUpdated = true;
				}
				else if (StrEqual(task.TaskType, "killsilent") && !StrEqual(weapon, "hegrenade") && IsSilenced(attacker))
				{
					task.CurrentProgress++;
					taskUpdated = true;
				}
				else if (StrEqual(task.TaskType, "killnoscope") && !StrEqual(weapon, "hegrenade") && IsNoScoped(attacker))
				{
					task.CurrentProgress++;
					taskUpdated = true;
				}
				else if (StrEqual(task.TaskType, "killjump") && IsInAir(attacker))
				{
					task.CurrentProgress++;
					taskUpdated = true;
				}
				else if (StrEqual(task.TaskType, "killvary") && IsNewWeapon(attacker))
				{
					task.CurrentProgress++;
					taskUpdated = true;
				}
				else if (StrEqual(task.TaskType, "killtrophy") && IsTrophyWeapon(weapon))
				{
					task.CurrentProgress++;
					taskUpdated = true;
				}
				else
					continue;

				// Update task completion
				CheckKillCompletion(attacker, task, i);
				g_Tasks.SetArray(i, task, sizeof(task));
				// Report task progress if not completed
				if (!task.Completed && taskUpdated)
					ShowTaskProgress(task);
			}
		}
	}
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	int victim   = GetClientOfUserId(event.GetInt("userid"));
	
	if (!IsValidClient(attacker))
		return;
	
	// Skip team damage
	if (GetClientTeam(attacker) == GetClientTeam(victim))
		return;
	
	int dmg = event.GetInt("dmg_health");
	if (dmg <= 0)
		return;
	
	char weapon[32];
	event.GetString("weapon", weapon, sizeof(weapon));
	
	// hitgroup 1 = head
	bool isHeadshot = (event.GetInt("hitgroup") == 1);
	
	for (int i = 0; i < g_Tasks.Length; i++)
	{
		AchievementTask task;
		g_Tasks.GetArray(i, task, sizeof(task));
		
		if (task.Completed)
			continue;
		
		if (task.RequireHeadshot && !isHeadshot)
			continue;
		
		bool taskUpdated = false;
		
		if (StrEqual(task.TaskType, "damage"))
		{
			task.CurrentProgress += dmg;
			taskUpdated = true;
		}
		else if (StrEqual(task.TaskType, "damagewith"))
		{
			if (IsWeaponClass(task.Weapon))
			{
				if (IsWeaponClassValid(weapon, task.Weapon))
				{
					task.CurrentProgress += dmg;
					taskUpdated = true;
				}
			}
			else if (StrEqual(weapon, task.Weapon))
			{
				task.CurrentProgress += dmg;
				taskUpdated = true;
			}
		}
		
		if (taskUpdated)
		{
			// Clamp progress to target so it doesn't wildly overflow in the display
			if (task.CurrentProgress > task.TargetValue)
				task.CurrentProgress = task.TargetValue;
			
			g_Tasks.SetArray(i, task, sizeof(task));
			
			// Immediate completion only when survival is not required
			if (!task.RequireSurvival && task.CurrentProgress >= task.TargetValue && !task.Completed)
				TaskCompleted(task, i);
			else if (!task.Completed)
				ShowTaskProgress(task);
		}
	}
}

public void CheckKillCompletion(int client, AchievementTask task, int taskIndex)
{
	// Check survival later
	if (task.RequireSurvival)
		return;
	
	// If task completed
	if (task.CurrentProgress >= task.TargetValue && !task.Completed)
		TaskCompleted(task, taskIndex);
}

public void TaskCompleted(AchievementTask task, int taskIndex)
{
	task.Completed = true;
	g_Tasks.SetArray(taskIndex, task, sizeof(task));
	
	// Show completed task for all players in the chat and play sound
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i))
		{
			EmitSoundToClient(i, TASK_COMPLETED);
			char message[128];
			GetTaskDescription(task, message, sizeof(message));
			PrintToChat(i, "\x04Task Completed: %s", message);
		}
	}
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	float roundTime = GetGameTime() - g_RoundStartTime;
	int winner = event.GetInt("winner");
	
	if (winner == CS_TEAM_CT)
	{
		for (int i = 0; i < g_hFollowedHostages.Length; i++)
			g_HostagesRescuedThisRound++;
		
		UpdateRescueTasks(false);
	}
	
	g_hFollowedHostages.Clear();
	
	// Singleplayer admin client
	bool survivor = true;
	
	// Check survival
	if (g_cvSimpleCoop.IntValue)
		survivor = (CountAlivePlayers() > 0);
	else
		survivor = !(CountDeadPlayers() > 0);
	
	// Iterate through all tasks
	for (int i = 0; i < g_Tasks.Length; i++)
	{
		AchievementTask task;
		g_Tasks.GetArray(i, task, sizeof(task));
		
		if (task.Completed)
			continue;
		
		if (StrEqual(task.TaskType, "winfast"))
		{
			if (roundTime <= task.TargetValue && GetClientTeam(1) == winner)
			{
				// Check for player alive for survival condition
				if (survivor)
					TaskCompleted(task, i);
			}
		}
		else if (task.RequireSurvival)
		{
			// Update task completion
			if (survivor && task.CurrentProgress >= task.TargetValue && !task.Completed)
			{
				char message[128];
				GetTaskDescription(task, message, sizeof(message));
				
				TaskCompleted(task, i);
			}
			else
			{
				// Reset weapons for killvary
				if (StrEqual(task.TaskType, "killvary") && task.RequireSurvival && !task.Completed)
					ResetWeapons();
				// If task not fully completed or player killed - reset task progress
				task.CurrentProgress = 0;
				g_Tasks.SetArray(i, task, sizeof(task));
			}
		}
	}
	
	// List tasks on round end
	ShowTaskList();
}

void UpdateRescueTasks(bool UpdateSingleHostage)
{
	for (int i = 0; i < g_Tasks.Length; i++)
	{
		AchievementTask task;
		g_Tasks.GetArray(i, task, sizeof(task));
		
		if (task.Completed) continue;
		
		if (StrEqual(task.TaskType, "rescue") && g_HostagesRescuedThisRound > 0)
		{
			// Add rescued count to progress
			if (UpdateSingleHostage)
				task.CurrentProgress++;
			else
				task.CurrentProgress += g_HostagesRescuedThisRound;
			g_Tasks.SetArray(i, task, sizeof(task));
			if (task.CurrentProgress >= task.TargetValue)
				TaskCompleted(task, i);
			else
				ShowTaskProgress(task);
		}
		else if (StrEqual(task.TaskType, "rescueall"))
		{
			// Requires all hostages rescued in one round
			if (g_HostagesRescuedThisRound >= g_TotalHostages && g_TotalHostages > 0)
				TaskCompleted(task, i);
		}
	}
}


public void CheckSurvivalCompletion(int client, AchievementTask task, int taskIndex)
{	

}

public void Event_HostageRescued(Event event, const char[] name, bool dontBroadcast)
{
	int hostage = event.GetInt("hostage");
	int index = g_hFollowedHostages.FindValue(hostage);
	if (index != -1)
		g_hFollowedHostages.Erase(index);
	
	g_HostagesRescuedThisRound++;
	
	UpdateRescueTasks(true);
}

public void Event_HostageFollows(Event event, const char[] name, bool dontBroadcast)
{
	int hostage = event.GetInt("hostage");
	if (IsValidHostage(hostage))
		g_hFollowedHostages.Push(hostage);
}

public void Event_HostageStopsFollowing(Event event, const char[] name, bool dontBroadcast)
{
	int hostage = event.GetInt("hostage");
	int index = g_hFollowedHostages.FindValue(hostage);
	if (index != -1)
		g_hFollowedHostages.Erase(index);

}

public void Event_HostageKilled(Event event, const char[] name, bool dontBroadcast)
{
	g_TotalHostages--;
	int hostage = event.GetInt("hostage");
	int index = g_hFollowedHostages.FindValue(hostage);
	if (index != -1)
		g_hFollowedHostages.Erase(index);
}

bool IsValidHostage(int entity)
{
	return (entity > MaxClients && IsValidEntity(entity) && IsValidEdict(entity));
}

public void GetTaskDescription(const AchievementTask task, char[] buffer, int maxlen)
{
	if (StrEqual(task.TaskType, "kill"))
	{
		Format(buffer, maxlen, "Kill %d enem%s%s%s%s%s%s %s%s%s%s",
			task.TargetValue,
			task.TargetValue != 1 ? "ies" : "y",
			task.RequireHeadshot ? " with headshot" : "",
			task.RequireHeadshot && task.TargetValue != 1 ? "s" : "",
			task.WithoutDying    ? " without dying"     : "",
			task.RequireNoReload ? " without reloading" : "",
			task.RequireSurvival ? " and survive the round" : "",
			!task.Completed && task.CurrentProgress > 0 ? "[" : "",
			!task.Completed && task.CurrentProgress > 0 ? FormatNumber(task.CurrentProgress) : "",
			!task.Completed && task.CurrentProgress > 0 ? "]" : "",
			task.Completed ? "[\xE2\x9C\x93]" : "");
	}
	else if (StrEqual(task.TaskType, "killwith"))
	{
		char weaponName[32];
		GetFormattedWeaponName(task.Weapon, weaponName, sizeof(weaponName));
		
		Format(buffer, maxlen, "Kill %d enem%s with %s%s%s%s%s%s %s%s%s%s", 
			task.TargetValue,
			task.TargetValue != 1 ? "ies" : "y",
			weaponName,
			task.RequireHeadshot ? " with headshot" : "",
			task.RequireHeadshot && task.TargetValue != 1 ? "s" : "",
			task.WithoutDying    ? " without dying"     : "",
			task.RequireNoReload ? " without reloading" : "",
			task.RequireSurvival ? " and survive the round" : "",
			!task.Completed && task.CurrentProgress > 0 ? "[" : "",
			!task.Completed && task.CurrentProgress > 0 ? FormatNumber(task.CurrentProgress) : "",
			!task.Completed && task.CurrentProgress > 0 ? "]" : "",
			task.Completed ? "[\xE2\x9C\x93]" : "");
	}
	else if (StrEqual(task.TaskType, "killblind"))
	{
		Format(buffer, maxlen, "Kill %d flashbang-blinded enem%s%s%s%s%s%s %s%s%s%s", 
			task.TargetValue,
			task.TargetValue != 1 ? "ies" : "y",
			task.RequireHeadshot ? " with headshot" : "",
			task.RequireHeadshot && task.TargetValue != 1 ? "s" : "",
			task.WithoutDying    ? " without dying"     : "",
			task.RequireNoReload ? " without reloading" : "",
			task.RequireSurvival ? " and survive the round" : "",
			!task.Completed && task.CurrentProgress > 0 ? "[" : "",
			!task.Completed && task.CurrentProgress > 0 ? FormatNumber(task.CurrentProgress) : "",
			!task.Completed && task.CurrentProgress > 0 ? "]" : "",
			task.Completed ? "[\xE2\x9C\x93]" : "");
	}
	else if (StrEqual(task.TaskType, "killsilent"))
	{
		Format(buffer, maxlen, "Kill %d enem%s with silenced weapon%s%s%s%s%s %s%s%s%s", 
			task.TargetValue,
			task.TargetValue != 1 ? "ies" : "y",
			task.RequireHeadshot ? " with headshot" : "",
			task.RequireHeadshot && task.TargetValue != 1 ? "s" : "",
			task.WithoutDying    ? " without dying"     : "",
			task.RequireNoReload ? " without reloading" : "",
			task.RequireSurvival ? " and survive the round" : "",
			!task.Completed && task.CurrentProgress > 0 ? "[" : "",
			!task.Completed && task.CurrentProgress > 0 ? FormatNumber(task.CurrentProgress) : "",
			!task.Completed && task.CurrentProgress > 0 ? "]" : "",
			task.Completed ? "[\xE2\x9C\x93]" : "");
	}
	else if (StrEqual(task.TaskType, "killnoscope"))
	{
		Format(buffer, maxlen, "Kill %d enem%s with an un-zoomed sniper rifle%s%s%s%s%s %s%s%s%s", 
			task.TargetValue,
			task.TargetValue != 1 ? "ies" : "y",
			task.RequireHeadshot ? " with headshot" : "",
			task.RequireHeadshot && task.TargetValue != 1 ? "s" : "",
			task.WithoutDying    ? " without dying"     : "",
			task.RequireNoReload ? " without reloading" : "",
			task.RequireSurvival ? " and survive the round" : "",
			!task.Completed && task.CurrentProgress > 0 ? "[" : "",
			!task.Completed && task.CurrentProgress > 0 ? FormatNumber(task.CurrentProgress) : "",
			!task.Completed && task.CurrentProgress > 0 ? "]" : "",
			task.Completed ? "[\xE2\x9C\x93]" : "");
	}
	else if (StrEqual(task.TaskType, "killjump"))
	{
		Format(buffer, maxlen, "Kill %d enem%s while you are airborne%s%s%s%s%s %s%s%s%s", 
			task.TargetValue,
			task.TargetValue != 1 ? "ies" : "y",
			task.RequireHeadshot ? " with headshot" : "",
			task.RequireHeadshot && task.TargetValue != 1 ? "s" : "",
			task.WithoutDying    ? " without dying"     : "",
			task.RequireNoReload ? " without reloading" : "",
			task.RequireSurvival ? " and survive the round" : "",
			!task.Completed && task.CurrentProgress > 0 ? "[" : "",
			!task.Completed && task.CurrentProgress > 0 ? FormatNumber(task.CurrentProgress) : "",
			!task.Completed && task.CurrentProgress > 0 ? "]" : "",
			task.Completed ? "[\xE2\x9C\x93]" : "");
	}
	else if (StrEqual(task.TaskType, "killvary"))
	{
		Format(buffer, maxlen, "Kill %d enem%s with different weapon%s%s%s%s%s%s %s%s%s%s", 
			task.TargetValue,
			task.TargetValue != 1 ? "ies" : "y",
			task.RequireHeadshot ? " with headshot" : "",
			task.RequireHeadshot && task.TargetValue != 1 ? "s" : "",
			task.RequireHeadshot && task.TargetValue != 1 ? "s" : "",
			task.WithoutDying    ? " without dying"     : "",
			task.RequireNoReload ? " without reloading" : "",
			task.RequireSurvival ? " and survive the round" : "",
			!task.Completed && task.CurrentProgress > 0 ? "[" : "",
			!task.Completed && task.CurrentProgress > 0 ? FormatNumber(task.CurrentProgress) : "",
			!task.Completed && task.CurrentProgress > 0 ? "]" : "",
			task.Completed ? "[\xE2\x9C\x93]" : "");
	}
	else if (StrEqual(task.TaskType, "killtrophy"))
	{
		Format(buffer, maxlen, "Kill %d enem%s with enemy's exclusive weapon%s%s%s%s %s%s%s%s",
			task.TargetValue,
			task.TargetValue != 1 ? "ies" : "y",
			task.RequireHeadshot ? " with headshots"    : "",
			task.WithoutDying    ? " without dying"     : "",
			task.RequireNoReload ? " without reloading" : "",
			task.RequireSurvival ? " and survive the round" : "",
			!task.Completed && task.CurrentProgress > 0 ? "[" : "",
			!task.Completed && task.CurrentProgress > 0 ? FormatNumber(task.CurrentProgress) : "",
			!task.Completed && task.CurrentProgress > 0 ? "]" : "",
			task.Completed ? "[\xE2\x9C\x93]" : "");
	}
	else if (StrEqual(task.TaskType, "damage"))
	{
		Format(buffer, maxlen, "Deal %d damage to enemies%s%s%s%s%s %s%s%s%s",
			task.TargetValue,
			task.RequireHeadshot ? " with headshots"    : "",
			task.WithoutDying    ? " without dying"     : "",
			task.RequireNoReload ? " without reloading" : "",
			task.RequireSurvival ? " and survive the round" : "",
			"",   // placeholder keeps arg count consistent
			!task.Completed && task.CurrentProgress > 0 ? "[" : "",
			!task.Completed && task.CurrentProgress > 0 ? FormatNumber(task.CurrentProgress) : "",
			!task.Completed && task.CurrentProgress > 0 ? "]" : "",
			task.Completed ? "[\xE2\x9C\x93]" : "");
	}
	else if (StrEqual(task.TaskType, "damagewith"))
	{
		char weaponName[32];
		GetFormattedWeaponName(task.Weapon, weaponName, sizeof(weaponName));
		
		Format(buffer, maxlen, "Deal %d damage to enemies with %s%s%s%s%s %s%s%s%s",
			task.TargetValue,
			weaponName,
			task.WithoutDying    ? " without dying"     : "",
			task.RequireNoReload ? " without reloading" : "",
			task.RequireSurvival ? " and survive the round" : "",
			"",   // placeholder
			!task.Completed && task.CurrentProgress > 0 ? "[" : "",
			!task.Completed && task.CurrentProgress > 0 ? FormatNumber(task.CurrentProgress) : "",
			!task.Completed && task.CurrentProgress > 0 ? "]" : "",
			task.Completed ? "[\xE2\x9C\x93]" : "");
	}
	else if (StrEqual(task.TaskType, "winfast"))
	{
		Format(buffer, maxlen, "Win round in %d seconds or faster%s %s", 
			task.TargetValue,
			task.RequireSurvival ? " and survive the round" : "",
			task.Completed ? "[\xE2\x9C\x93]" : "");
	}
	else if (StrEqual(task.TaskType, "rescue"))
	{
		Format(buffer, maxlen, "Rescue %d hostage%s %s%s%s%s", 
			task.TargetValue,
			task.TargetValue != 1 ? "s" : "",
			!task.Completed && task.CurrentProgress > 0 ? "[" : "",
			!task.Completed && task.CurrentProgress > 0 ? FormatNumber(task.CurrentProgress) : "",
			!task.Completed && task.CurrentProgress > 0 ? "]" : "",
			task.Completed ? "[\xE2\x9C\x93]" : "");
			
	}
	else if (StrEqual(task.TaskType, "spray"))
	{
		Format(buffer, maxlen, "Tag %d spray%s %s%s%s%s", 
			task.TargetValue,
			task.TargetValue != 1 ? "s" : "",
			!task.Completed && task.CurrentProgress > 0 ? "[" : "",
			!task.Completed && task.CurrentProgress > 0 ? FormatNumber(task.CurrentProgress) : "",
			!task.Completed && task.CurrentProgress > 0 ? "]" : "",
			task.Completed ? "[\xE2\x9C\x93]" : "");
	}
	else if (StrEqual(task.TaskType, "rescueall"))
	{
		Format(buffer, maxlen, "Rescue all hostages %s",
			task.Completed ? "[\xE2\x9C\x93]" : "");
	}
	else if (StrEqual(task.TaskType, "bomb"))
	{
		Format(buffer, maxlen, "Defuse/Plant bomb %s",
			task.Completed ? "[\xE2\x9C\x93]" : "");
	}
}

void GetFormattedWeaponName(const char[] weapon, char[] buffer, int maxlen)
{
	StringMap weaponNames = new StringMap();
	
	weaponNames.SetString("glock",		"9x19mm Sidearm");			// Glock 19
	weaponNames.SetString("usp",		"K&M .45 Tactical");		// H&K USP Tactical
	weaponNames.SetString("p228",		"228 Compact");				// SIG P228
	weaponNames.SetString("deagle",		"Night Hawk .50c");			// Desert Eagle
	weaponNames.SetString("elite",		".40 Dual Elites");			// Dual Berettas
	weaponNames.SetString("fiveseven",	"ES Five-Seven");			// FN Five-seveN
	
	weaponNames.SetString("m3",			"Leone 12 Gauge");			// Benelli M3 Super 90
	weaponNames.SetString("xm1014",		"Leone YG1265 Auto");		// Benelli M4 Super 90
	
	weaponNames.SetString("mac10",		"Ingram Mac-10");			// Ingram MAC-10
	weaponNames.SetString("tmp",		"Schmidt Machine Pistol");	// Steyr TMP
	weaponNames.SetString("mp5navy",	"K&M Sub-Machine Gun");		// H&K MP5N
	weaponNames.SetString("ump45",		"K&M UMP45");				// H&K UMP45
	weaponNames.SetString("p90",		"ES C90");					// FN P90
	
	weaponNames.SetString("galil",		"IDF Defender");			// IMI Galil AR
	weaponNames.SetString("famas",		"Clarion 5.56");			// FAMAS F1
	weaponNames.SetString("ak47",		"CV-47");					// AK-47
	weaponNames.SetString("m4a1",		"Maverick M4A1 Carbine");	// M4A1 Carbine
	weaponNames.SetString("sg552",		"Krieg 552");				// SIG SG 552 Commando
	weaponNames.SetString("aug",		"Bullpup");					// Steyr AUG
	
	weaponNames.SetString("scout",		"Schmidt Scout");			// Steyr Scout
	weaponNames.SetString("awp",		"Magnum Sniper Rifle");		// AWP
	weaponNames.SetString("g3sg1",		"D3/AU-1");					// H&K G3SG/1
	weaponNames.SetString("sg550",		"Krieg 550 Commando");		// SIG SG 550
	
	weaponNames.SetString("m249",		"M249");					// FN Minimi
	
	weaponNames.SetString("hegrenade",	"HE Grenade");
	weaponNames.SetString("knife",		"Knife");
	
	weaponNames.SetString("pistol",		"Pistol");
	weaponNames.SetString("shotgun",	"Shotgun");
	weaponNames.SetString("smg",		"Submachine Gun");
	weaponNames.SetString("rifle",		"Assault Rifle");
	weaponNames.SetString("sniper",		"Sniper Rifle");
	weaponNames.SetString("machinegun",	"Machine Gun");


	if (!weaponNames.GetString(weapon, buffer, maxlen))
	{
		// Fallback: Capitalize first letter
		strcopy(buffer, maxlen, weapon);
		if (strlen(buffer) > 0)
			buffer[0] = CharToUpper(buffer[0]);
	}
	
	delete weaponNames;
}

char[] FormatNumber(int value)
{
	char buffer[16];
	IntToString(value, buffer, sizeof(buffer));
	return buffer;
}

int ParseTargetValue(const char[] buffer)
{
	char parts[16][32];
	int numParts = ExplodeString(buffer, " ", parts, sizeof(parts), sizeof(parts[]));

	// Find the first numeric value after the task type
	for (int i = 0; i < numParts; i++)
		if (String_IsNumeric(parts[i]))
			return StringToInt(parts[i]);
		
	// Fallback if no valid number found
	return 0;
}

bool String_IsNumeric(const char[] str)
{
	int len = strlen(str);
	for (int i = 0; i < len; i++)
		if (!IsCharNumeric(str[i]))
			return false;
		
	return (len > 0);
}

void ParseWeapon(const char[] buffer, char[] weapon, int maxlen)
{
	char teamweapon[32];
	char parts[16][32];
	int numParts = ExplodeString(buffer, " ", parts, sizeof(parts), sizeof(parts[]));
	bool foundTarget = false;

	for (int i = 0; i < numParts; i++)
	{
		// Skip the task type and target value
		if (String_IsNumeric(parts[i]))
		{
			foundTarget = true;
			continue;
		}

		// Capture the first non-keyword after the target value
		if (foundTarget && !StrEqual(parts[i], "inarow") && !StrEqual(parts[i], "survive") && !StrEqual(parts[i], "headshot") && !StrEqual(parts[i], "noreload"))
		{
			strcopy(weapon, maxlen, parts[i]);
			StringToLower(weapon);
		}
	}
	
	// Replace for current team
	StringMap weaponNames = new StringMap();
	
	if (IsHumanTeamCT())
	{
		weaponNames.SetString("elite",		"fiveseven");
		weaponNames.SetString("mac10",		"tmp");
		weaponNames.SetString("galil",		"famas");
		weaponNames.SetString("ak47",		"m4a1");
		weaponNames.SetString("sg552",		"aug");
		weaponNames.SetString("g3sg1",		"sg550");
	}
	else
	{
		weaponNames.SetString("fiveseven",	"elite");
		weaponNames.SetString("tmp",		"mac10");
		weaponNames.SetString("famas",		"galil");
		weaponNames.SetString("m4a1",		"ak47");
		weaponNames.SetString("aug",		"sg552");
		weaponNames.SetString("sg550",		"g3sg1");
	}
	
	if (weaponNames.GetString(weapon, teamweapon, maxlen))
		strcopy(weapon, maxlen, teamweapon);
	
	delete weaponNames;
	
}

void StringToLower(char[] str)
{
	int len = strlen(str);
	for (int i = 0; i < len; i++)
	{
		str[i] = CharToLower(str[i]);
	}
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_RoundStartTime = GetGameTime() + g_cvFreezeTime.FloatValue;
	g_HostagesRescuedThisRound = 0;
	g_TotalHostages = 0;
	
	// Extra completion check
	CheckVictory(false);
	
	// Show tasks on first round
	if (!CS_GetTeamScore(CS_TEAM_CT) && !CS_GetTeamScore(CS_TEAM_T))
		ShowTaskList();
	
	// Count valid hostages
	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "hostage_entity")) != -1)
		g_TotalHostages++;
	
	// Check if human team is T and map has bomb targets
	if (IsHumanTeamT() && MapHasBombTarget())
	{
		CreateTimer(0.5, Timer_GiveC4ToHuman); // Delay for safe equipment handling
	}
}

public void Event_WeaponReload(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsValidClient(client) && !IsFakeClient(client))
        OnPlayerReload();
}

void OnPlayerReload()
{
    for (int i = 0; i < g_Tasks.Length; i++)
    {
        AchievementTask task;
        g_Tasks.GetArray(i, task, sizeof(task));

        if (!task.Completed && task.RequireNoReload)
        {
            task.CurrentProgress = 0;
            g_Tasks.SetArray(i, task, sizeof(task));
        }
    }
}

public void Event_PlayerBlind(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	float duration = GetEntPropFloat(client, Prop_Send, "m_flFlashDuration");
	g_bBlinded[client] = true;
	CreateTimer(duration, Timer_Unblind, GetClientUserId(client));
}

public Action Timer_Unblind(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	g_bBlinded[client] = false;
	return Plugin_Continue;
}

public void Event_BombPlanted(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	int team = GetClientTeam(client);
	if (IsValidClient(client) && !IsFakeClient(client) && team == CS_TEAM_T) 
	{
		// Iterate through all tasks
		for (int i = 0; i < g_Tasks.Length; i++)
		{
			AchievementTask task;
			g_Tasks.GetArray(i, task, sizeof(task));
			
			if (!task.Completed)
			{
				if (StrEqual(task.TaskType, "bomb"))
				{
					if (!task.Completed)
						TaskCompleted(task, i);
				}
			}
		}
	}
}

public void Event_BombDefused(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	int team = GetClientTeam(client);
	if (IsValidClient(client) && !IsFakeClient(client) && team == CS_TEAM_CT) 
	{
		// Iterate through all tasks
		for (int i = 0; i < g_Tasks.Length; i++)
		{
			AchievementTask task;
			g_Tasks.GetArray(i, task, sizeof(task));
			
			if (!task.Completed)
			{
				if (StrEqual(task.TaskType, "bomb"))
				{
					if (!task.Completed)
						TaskCompleted(task, i);
				}
			}
		}
	}
}

public void ShowTaskList()
{
	ClearChat();
	// Show task list for all players in the chat
	for (int i = 1; i <= MaxClients; i++)
		if (IsValidClient(i))
			Command_ListTasks(i, 0);
}

public void ShowTaskProgress(AchievementTask task)
{
	// Show task progress for all players in the chat
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i))
		{
			char message[128];
			GetTaskDescription(task, message, sizeof(message));
			PrintToChat(i, "Task Progress: %s", message);
		}
	}
}

public Action Command_ListTasks(int client, int args)
{
	ClearChat();
	// If command from server, show to all clients
	if (client == 0)
	{
		for (int i = 1; i <= MaxClients; i++)
			if (IsValidClient(i))
				Command_ListTasks(i, 0);
		return Plugin_Handled;
	}
	
	if (g_Tasks.Length == 0)
	{
		PrintToChat(client, "No active tasks!");
		return Plugin_Handled;
	}

	PrintToChat(client, "CT:%i T:%i", CS_GetTeamScore(CS_TEAM_CT), CS_GetTeamScore(CS_TEAM_T));
	
	for (int i = 0; i < g_Tasks.Length; i++)
	{
		AchievementTask task;
		g_Tasks.GetArray(i, task, sizeof(task));
		
		char desc[128];
		GetTaskDescription(task, desc, sizeof(desc));
		
		PrintToChat(client, "%s%d. %s", 
			task.Completed ? "\x04" : "", // Green color for completed
			i+1,
			desc);
	}
	
	// Check team score
	int ct_wins = CS_GetTeamScore(CS_TEAM_CT);
	int t_wins = CS_GetTeamScore(CS_TEAM_T);
	int wins_by = ct_wins - t_wins;
	int wins = ct_wins + t_wins;
	
	if (AllTasksCompleted() && wins < g_cvMatchwins.IntValue)
		PrintToChat(client, "At least %d round%s should be played to verify winner", g_cvMatchwins.IntValue, g_cvMatchwins.IntValue == 1 ? "" : "s");
	if (AllTasksCompleted() && wins_by < g_cvMatchwinsby.IntValue && wins_by > -g_cvMatchwinsby.IntValue)
		PrintToChat(client, "Your team should lead by %d point%s to win the match", g_cvMatchwinsby.IntValue, g_cvMatchwinsby.IntValue == 1 ? "" : "s");
	
	return Plugin_Handled;
}

public Action Command_DeleteAllTasks(int client, int args)
{
	g_Tasks.Clear();
	PrintToServer("All tasks have been deleted.");
	
	return Plugin_Handled;
}

public Action Command_ResetAllProgress(int client, int args)
{
	for (int i = 0; i < g_Tasks.Length; i++)
	{
		AchievementTask task;
		g_Tasks.GetArray(i, task, sizeof(task));
		
		for (int p = 1; p <= MaxClients; p++)
		{
			task.CurrentProgress = 0;
			task.Completed = false;
		}
		
		g_Tasks.SetArray(i, task, sizeof(task));
	}
	ResetWeapons();
	PrintToServer("All task progress has been reset.");
	return Plugin_Handled;
}

// Client is valid Player and not bot
bool IsValidClient(int client)
{
	return (1 <= client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client));
}

public int CountRealPlayers()
{
	int i = 0;
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsValidClient(client))
			i++;
	}
	
	return i;
}

public int CountAlivePlayers()
{
	int i = 0;
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsValidClient(client) && IsPlayerAlive(client))
			i++;
	}
	
	return i;
}

public int CountDeadPlayers()
{
	int i = 0;
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsValidClient(client) && !IsPlayerAlive(client))
			i++;
	}
	
	return i;
}


public int CountEnemyTeam()
{
	// Determine human team
	char humanTeam[8];
	g_cvHumanTeam.GetString(humanTeam, sizeof(humanTeam));
	int enemyTeam = StrEqual(humanTeam, "CT", false) ? CS_TEAM_T : CS_TEAM_CT;
	
	int enemies = 0;
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsClientSourceTV(i) && GetClientTeam(i) == enemyTeam)
		enemies++;
	}
	
	return enemies;
}

bool AllTasksCompleted()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsValidClient(client) && !IsFakeClient(client))
		{
			for (int i = 0; i < g_Tasks.Length; i++)
			{
				AchievementTask task;
				g_Tasks.GetArray(i, task, sizeof(task));
				
				if (!task.Completed)
					return false;
			}
		}
	}
	return true;
}

public Action Command_Victory(int client, int args)
{
	if (g_cvCheats.IntValue)
		MissionCompleted();
	else
		PrintToServer("Not allowed with sv_cheats 0");
	
	return Plugin_Handled;
}

public Action Command_Defeat(int client, int args)
{
	if (g_cvCheats.IntValue)
		MissionFailed();
	else
		PrintToServer("Not allowed with sv_cheats 0");
	
	return Plugin_Handled;
}

bool IsWeaponClass(const char[] weaponclass)
{
	if (StrEqual(weaponclass, "pistol") ||
		StrEqual(weaponclass, "shotgun") ||
		StrEqual(weaponclass, "smg") ||
		StrEqual(weaponclass, "rifle") ||
		StrEqual(weaponclass, "sniper") ||
		StrEqual(weaponclass, "machinegun"))
		return true;
	return false;
}

bool IsWeaponClassValid(const char[] weapon, const char[] weaponclass)
{
	if (StrEqual(weaponclass, "pistol"))
	{
		if (StrEqual(weapon, "glock") ||
			StrEqual(weapon, "usp") ||
			StrEqual(weapon, "p228") ||
			StrEqual(weapon, "deagle") ||
			StrEqual(weapon, "fiveseven") ||
			StrEqual(weapon, "elite"))
			return true;
	}
	else if (StrEqual(weaponclass, "shotgun"))
	{
		if (StrEqual(weapon, "m3") ||
			StrEqual(weapon, "xm1014"))
			return true;
	}
	else if (StrEqual(weaponclass, "smg"))
	{
		if (StrEqual(weapon, "tmp") ||
			StrEqual(weapon, "mac10") ||
			StrEqual(weapon, "mp5navy") ||
			StrEqual(weapon, "ump45") ||
			StrEqual(weapon, "p90"))
			return true;
	}
	else if (StrEqual(weaponclass, "rifle"))
	{
		if (StrEqual(weapon, "galil") ||
			StrEqual(weapon, "famas") ||
			StrEqual(weapon, "m4a1") ||
			StrEqual(weapon, "ak47") ||
			StrEqual(weapon, "aug") ||
			StrEqual(weapon, "sg552"))
			return true;
	}
	else if (StrEqual(weaponclass, "sniper"))
	{
		if (StrEqual(weapon, "scout") ||
			StrEqual(weapon, "sg550") ||
			StrEqual(weapon, "g3sg1") ||
			StrEqual(weapon, "awp"))
			return true;
	}
	else if (StrEqual(weaponclass, "machinegun"))
		if (StrEqual(weapon, "m249"))
			return true;
	return false;
}

// New command handler
public Action Command_Autobuy(int client, int args)
{
	if (!IsValidClient(client)) return Plugin_Handled;
	
	if (g_bUseOriginalAutobuy)
	{
		// Allow original game logic to handle this call
		return Plugin_Continue;
	}
	
	// Get all active killwith / damagewith weapons
	ArrayList weapons = new ArrayList(32);
	for (int i = 0; i < g_Tasks.Length; i++)
	{
		AchievementTask task;
		g_Tasks.GetArray(i, task, sizeof(task));
		if ((StrEqual(task.TaskType, "killwith") || StrEqual(task.TaskType, "damagewith")) && !task.Completed)
			weapons.PushString(task.Weapon);
		else if (StrEqual(task.TaskType, "killblind") && !task.Completed)
			weapons.PushString("flashbang");
		else if (StrEqual(task.TaskType, "killsilent") && !task.Completed)
			weapons.PushString("silent");
		else if (StrEqual(task.TaskType, "killnoscope") && !task.Completed)
			weapons.PushString("sniper");
	}
	
	BuyWeapons(client, weapons);
	
	delete weapons;
	return Plugin_Handled; // Block default autobuy
}

void BuyWeapons(int client, ArrayList weapons)
{
	char weapon[32];
	bool boughtPrimary;
	bool boughtSecondary;
	int money = GetEntProp(client, Prop_Send, "m_iAccount");
	int team = GetClientTeam(client);
	
	// First pass: primary weapons
	for (int i = 0; i < weapons.Length; i++)
	{
		weapons.GetString(i, weapon, sizeof(weapon));
		if (IsPrimaryWeapon(weapon) && money >= GetPrice(weapon) && !boughtPrimary)
		{
			FakeClientCommand(client, "buy %s", weapon);
			boughtPrimary = true;
		}
		else if (IsWeaponClass(weapon) && !StrEqual(weapon, "pistol") && !boughtPrimary)
		{
			if (StrEqual(weapon, "shotgun"))
			{
				if (money >= GetPrice("xm1014"))
					FakeClientCommand(client, "buy xm1014");
				else if (money >= GetPrice("m3"))
					FakeClientCommand(client, "buy m3");
			}
			else if (StrEqual(weapon, "smg"))
			{
				if (money >= GetPrice("p90"))
					FakeClientCommand(client, "buy p90");
				else if (money >= GetPrice("ump45"))
					FakeClientCommand(client, "buy ump45");
				else if (money >= GetPrice("mp5navy"))
					FakeClientCommand(client, "buy mp5navy");
				else if (team == CS_TEAM_T && money >= GetPrice("mac10"))
					FakeClientCommand(client, "buy mac10");
				else if (team == CS_TEAM_CT && money >= GetPrice("tmp"))
					FakeClientCommand(client, "buy tmp");
			}
			else if (StrEqual(weapon, "rifle"))
			{
				if (team == CS_TEAM_T && money >= GetPrice("sg552"))
					FakeClientCommand(client, "buy sg552");
				else if (team == CS_TEAM_CT && money >= GetPrice("aug"))
					FakeClientCommand(client, "buy aug");
				else if (team == CS_TEAM_CT && money >= GetPrice("m4a1"))
					FakeClientCommand(client, "buy m4a1");
				else if (team == CS_TEAM_T && money >= GetPrice("ak47"))
					FakeClientCommand(client, "buy ak47");
				else if (team == CS_TEAM_CT && money >= GetPrice("famas"))
					FakeClientCommand(client, "buy famas");
				else if (team == CS_TEAM_T && money >= GetPrice("galil"))
					FakeClientCommand(client, "buy galil");
			}
			else if (StrEqual(weapon, "sniper"))
			{
				if (team == CS_TEAM_T && money >= GetPrice("g3sg1"))
					FakeClientCommand(client, "buy g3sg1");
				else if (money >= GetPrice("awp"))
					FakeClientCommand(client, "buy awp");
				else if (team == CS_TEAM_CT && money >= GetPrice("sg550"))
					FakeClientCommand(client, "buy sg550");
				else if (money >= GetPrice("scout"))
					FakeClientCommand(client, "buy scout");
			}
			else if (StrEqual(weapon, "machinegun"))
			{
				if (money >= GetPrice("m249"))
					FakeClientCommand(client, "buy m249");
			}
			else if (StrEqual(weapon, "silent"))
			{
				if (team == CS_TEAM_CT)
				{
					if (money >= GetPrice("m4a1"))
						FakeClientCommand(client, "buy m4a1");
					else if (money >= GetPrice("tmp"))
						FakeClientCommand(client, "buy tmp");
				}
			}
			boughtPrimary = true;
		}
		else if (IsSecondaryWeapon(weapon) && money >= GetPrice(weapon) && !boughtSecondary)
		{
			FakeClientCommand(client, "buy %s", weapon);
			boughtSecondary = true;
		}
		else if (StrEqual(weapon, "silent") && team == CS_TEAM_T && money >= GetPrice("usp") && !boughtSecondary)
		{
			FakeClientCommand(client, "buy usp");
		}
		else if (StrEqual(weapon, "pistol") && !boughtSecondary)
		{
			if (team == CS_TEAM_T && money >= GetPrice("elite"))
				FakeClientCommand(client, "buy elite");
			else if (team == CS_TEAM_CT && money >= GetPrice("fiveseven"))
				FakeClientCommand(client, "buy fiveseven");
			else if (money >= GetPrice("deagle"))
				FakeClientCommand(client, "buy deagle");
			else if (money >= GetPrice("p228"))
				FakeClientCommand(client, "buy p228");
			boughtSecondary = true;
		}
		else if (IsGrenade(weapon))
		{
			if (StrEqual(weapon, "hegrenade") && money >= GetPrice("hegrenade"))
				FakeClientCommand(client, "buy hegrenade");
			if (StrEqual(weapon, "flashbang") && money >= GetPrice("flashbang"))
			{
				FakeClientCommand(client, "buy flashbang");
				// Double purchase for the flashbang
				if (money >= GetPrice("flashbang"))
					FakeClientCommand(client, "buy flashbang");
			}
		}
	}
	
	// Proceed vanilla autobuy if no primary weapon
	if (!boughtPrimary)
	{
		// Execute original autobuy
		g_bUseOriginalAutobuy = true;
		FakeClientCommand(client, "autobuy");
		g_bUseOriginalAutobuy = false;
	}
	else
	{
		if (team == CS_TEAM_CT && !PlayerHasC4orDefuser(client) && money >= GetPrice("defuser"))
			FakeClientCommand(client, "buy defuser");
		
		if (!PlayerHasHelmet(client) && money >= GetPrice("vesthelm"))
			FakeClientCommand(client, "buy vesthelm");
		else if (!PlayerHasFullArmor(client) && money >= GetPrice("vest"))
			FakeClientCommand(client, "buy vest");
	}
}

int GetPrice(const char[] item)
{
	if (StrEqual(item, "glock"))
		return 400;
	else if (StrEqual(item, "usp"))
		return 500;
	else if (StrEqual(item, "p228"))
		return 600;
	else if (StrEqual(item, "deagle"))
		return 650;
	else if (StrEqual(item, "fiveseven"))
		return 750;
	else if (StrEqual(item, "elite"))
		return 800;
	else if (StrEqual(item, "m3"))
		return 1700;
	else if (StrEqual(item, "xm1014"))
		return 3000;
	else if (StrEqual(item, "galil"))
		return 2000;
	else if (StrEqual(item, "ak47"))
		return 2500;
	else if (StrEqual(item, "scout"))
		return 2750;
	else if (StrEqual(item, "sg552"))
		return 3500;
	else if (StrEqual(item, "awp"))
		return 4750;
	else if (StrEqual(item, "g3sg1"))
		return 5000;
	else if (StrEqual(item, "famas"))
		return 2250;
	else if (StrEqual(item, "m4a1"))
		return 3100;
	else if (StrEqual(item, "aug"))
		return 3500;
	else if (StrEqual(item, "sg550"))
		return 4200;
	else if (StrEqual(item, "mac10"))
		return 1400;
	else if (StrEqual(item, "tmp"))
		return 1250;
	else if (StrEqual(item, "mp5navy"))
		return 1500;
	else if (StrEqual(item, "ump45"))
		return 1700;
	else if (StrEqual(item, "p90"))
		return 2350;
	else if (StrEqual(item, "m249"))
		return 5750;
	else if (StrEqual(item, "hegrenade"))
		return 300;
	else if (StrEqual(item, "vest"))
		return 650;
	else if (StrEqual(item, "vesthelm"))
		return 1000;
	else if (StrEqual(item, "flashbang"))
		return 200;
	else if (StrEqual(item, "smokegrenade"))
		return 300;
	else if (StrEqual(item, "defuser"))
		return 200;
	else if (StrEqual(item, "nvgs"))
		return 1250;
	
	return 0;
}

bool PlayerHasC4orDefuser(int client)
{
	return GetPlayerWeaponSlot(client, 4) != -1;
}

bool PlayerHasHelmet(int client)
{
	return GetEntProp(client, Prop_Send, "m_bHasHelmet");
}

bool PlayerHasFullArmor(int client)
{
	return GetEntProp(client, Prop_Data, "m_ArmorValue") == 100;
}

bool IsPrimaryWeapon(const char[] weapon)
{
	return	StrEqual(weapon, "m3") ||
			StrEqual(weapon, "xm1014") ||
			StrEqual(weapon, "galil") ||
			StrEqual(weapon, "ak47") ||
			StrEqual(weapon, "scout") ||
			StrEqual(weapon, "sg552") ||
			StrEqual(weapon, "g3sg1") ||
			StrEqual(weapon, "awp") ||
			StrEqual(weapon, "famas") ||
			StrEqual(weapon, "m4a1") ||
			StrEqual(weapon, "aug") ||
			StrEqual(weapon, "sg550") ||
			StrEqual(weapon, "mac10") ||
			StrEqual(weapon, "tmp") ||
			StrEqual(weapon, "mp5navy") ||
			StrEqual(weapon, "ump45") ||
			StrEqual(weapon, "p90") ||
			StrEqual(weapon, "m249");
}

bool IsSecondaryWeapon(const char[] weapon)
{
	return	StrEqual(weapon, "glock") ||
			StrEqual(weapon, "usp") ||
			StrEqual(weapon, "p228") ||
			StrEqual(weapon, "deagle") ||
			StrEqual(weapon, "elite") ||
			StrEqual(weapon, "fiveseven");
}

bool IsGrenade(const char[] weapon)
{
	return	StrEqual(weapon, "hegrenade") ||
			StrEqual(weapon, "flashbang") ||
			StrEqual(weapon, "smokegrenade");
}

public Action Command_NextRound(int client, int args)
{
	// Determine human team
	char humanTeam[8];
	g_cvHumanTeam.GetString(humanTeam, sizeof(humanTeam));
	int teamToKill = StrEqual(humanTeam, "CT", false) ? CS_TEAM_CT : CS_TEAM_T;

	// Kill all players (humans + bots) in human team
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsClientSourceTV(i) && GetClientTeam(i) == teamToKill)
			ForcePlayerSuicide(i);
	}
	
	return Plugin_Handled;
}

public Action Timer_ForceRoundEnd(Handle timer, DataPack dp)
{
	dp.Reset();
	int winningTeam = dp.ReadCell();
	delete dp;

	CS_TerminateRound(1.0, (winningTeam == CS_TEAM_CT) ? CSRoundEnd_CTWin : CSRoundEnd_TerroristWin, true);
	return Plugin_Stop;
}

bool MapHasBombTarget()
{
	int entity = -1;
	while((entity = FindEntityByClassname(entity, "func_bomb_target")) != -1)
	{
		if (IsValidEntity(entity)) return true;
	}
	return false;
}

public Action Timer_GiveC4ToHuman(Handle timer)
{
	ArrayList humans = new ArrayList();
	
	// Find all human T players
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i) && GetClientTeam(i) == CS_TEAM_T && !IsFakeClient(i))
			humans.Push(i);
	}
	
	if (humans.Length > 0)
	{
		// Remove existing C4 from all players
		RemoveAllC4();
		
		// Select random human
		int client = humans.Get(GetRandomInt(0, humans.Length - 1));
		
		// Give C4
		GivePlayerItem(client, "weapon_c4");
	}
	
	delete humans;
	return Plugin_Stop;
}

public Action Timer_CheckClip(Handle timer)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidClient(client) || !IsPlayerAlive(client))
            continue;

        int weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
        if (weapon == -1 || !IsValidEntity(weapon))
        {
            g_iLastClip[client] = -1;
            continue;
        }

        int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");

        // Auto reload
        if (g_iLastClip[client] > 0 && clip == 0)
            OnPlayerReload();

        g_iLastClip[client] = clip;
    }
    return Plugin_Continue;
}

void RemoveAllC4()
{
	int weapon;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsClientSourceTV(i) && IsClientConnected(i) && IsPlayerAlive(i))
		{
			while((weapon = GetPlayerWeaponSlot(i, 4)) != -1) // C4 slot
			{
				RemovePlayerItem(i, weapon);
				AcceptEntityInput(weapon, "Kill");
			}
		}
	}
}

bool IsNoScoped(int client)
{
	int weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
	if (weapon == -1 || !IsValidEntity(weapon))
		return false;
	
	char classname[32];
	GetEntityClassname(weapon, classname, sizeof(classname));
	
	if (StrEqual(classname, "weapon_scout") || StrEqual(classname, "weapon_sg550") || StrEqual(classname, "weapon_g3sg1") || StrEqual(classname, "weapon_awp"))
		return !IsZoomed(client)

	return false;
}

bool IsZoomed(int client)
{
	if (GetEntPropEnt(client, Prop_Send, "m_hZoomOwner") != -1 && GetEntProp(client, Prop_Send, "m_iFOV") != GetEntProp(client, Prop_Send, "m_iDefaultFOV"))
		return true;

	return false;
}

bool IsSilenced(int client)
{
	int weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
	if (weapon == -1 || !IsValidEntity(weapon))
		return false;
	
	char classname[32];
	GetEntityClassname(weapon, classname, sizeof(classname));
	
	if (StrEqual(classname, "weapon_knife") || StrEqual(classname, "weapon_tmp"))
		return true;
	else if (StrEqual(classname, "weapon_m4a1") || StrEqual(classname, "weapon_usp"))
		return GetEntProp(weapon, Prop_Send, "m_bSilencerOn") == 1;
	
	return false;
}

bool IsTrophyWeapon(const char[] weapon)
{
    if (IsHumanTeamCT())
    {
        return  StrEqual(weapon, "elite")  ||
                StrEqual(weapon, "mac10")  ||
                StrEqual(weapon, "galil")  ||
                StrEqual(weapon, "ak47")   ||
                StrEqual(weapon, "sg552")  ||
                StrEqual(weapon, "g3sg1");
    }
    else
    {
        return  StrEqual(weapon, "fiveseven") ||
                StrEqual(weapon, "tmp")       ||
                StrEqual(weapon, "famas")     ||
                StrEqual(weapon, "m4a1")      ||
                StrEqual(weapon, "aug")       ||
                StrEqual(weapon, "sg550");
    }
}

bool IsInAir(int client)
{
	return !(GetEntityFlags(client) & FL_ONGROUND);
}

bool IsNewWeapon(int client)
{
	int weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
	if (weapon == -1 || !IsValidEntity(weapon))
		return false;
	
	char classname[32];
	GetEntityClassname(weapon, classname, sizeof(classname));
	
	if (g_UsedWeapons.FindString(classname) == -1)
	{
		g_UsedWeapons.PushString(classname);
		return true;
	}
	
	return false;
}

void ResetWeapons()
{
	g_UsedWeapons.Clear();
}

void ClearChat()
{
	PrintToChatAll(" \n \n \n \n \n \n \n \n");
}

public Action:PlayerSpray(const String:szTempEntName[], const arrClients[], iClientCount, Float:flDelay) 
{
	new client = TE_ReadNum("m_nPlayer");
	if (IsValidClient(client) && !IsFakeClient(client)) 
	{
		// Iterate through all tasks
		for (int i = 0; i < g_Tasks.Length; i++)
		{
			AchievementTask task;
			g_Tasks.GetArray(i, task, sizeof(task));
			
			if (!task.Completed)
			{
				if (StrEqual(task.TaskType, "spray"))
				{
					task.CurrentProgress++;
					g_Tasks.SetArray(i, task, sizeof(task));
					
					if (!task.Completed)
						ShowTaskProgress(task);
					
					if (task.CurrentProgress >= task.TargetValue && !task.Completed)
						TaskCompleted(task, i);
				}
			}
		}
	}
}
