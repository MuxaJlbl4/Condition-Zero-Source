#include <sourcemod>
#include <cstrike>
#include <smlib>

new const String:PLUGIN_NAME[]= "CS:S Bot2Player"
new const String: PLUGIN_AUTHOR[]= "Bittersweet"
new const String:PLUGIN_DESCRIPTION[]= "Allows players to control bots after they've died (adapted from botcontrol for TF2 by Grognak)"
new const String: PLUGIN_VERSION[]= "public.2013.06.30.15.51"
new Handle:cvar_b2p_enabled = INVALID_HANDLE
new Handle:cvar_Round_Restart_Delay  = INVALID_HANDLE
new Handle:cvar_BotTakeOverStartingCost = INVALID_HANDLE
new Handle:cvar_BotTakeOverCostIncrement = INVALID_HANDLE

//These are default values, actually set from bot2player.cfg file
new BotTakeOverStartingCost = 0
new BotTakeOverCostIncrement = 0

new bool:bHideDeath[MAXPLAYERS + 1] = {false, ...};
new ClientSpecClient[MAXPLAYERS + 1] = {0, ...}
new ClientTookover[MAXPLAYERS + 1] = {0, ...}
new WrongTeamWarning[MAXPLAYERS + 1] = {0, ...}
new TeleportWarning[MAXPLAYERS + 1] = {0, ...}
new BotTakeverCost[MAXPLAYERS + 1] = {0, ...}
new Nades[MAXPLAYERS + 1][3]

new Float:Round_Restart_Delay = 0.0
new Float:Weapon_Strip_Delay = 0.0
new bool:b2pEnabled
new iTargetActiveWeapon
new g_offObserverTarget
new iTargetWeapon[5]
new iTargetClip[5]
new iTargetAmmo[5]
new g_iAccount = -1
new gameround = 1

new String:iTargetActiveWeaponName[32]

public Plugin:myinfo =
{
	name        = PLUGIN_NAME,
	author      = PLUGIN_AUTHOR,
	description = PLUGIN_DESCRIPTION,
	version     = PLUGIN_VERSION,
}
public OnPluginStart()
{
	PrintToServer("[%s %s] - Loaded", PLUGIN_NAME, PLUGIN_VERSION)
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre)
	HookEvent("round_start", Event_RoundStart)
	HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre)
	// round_freeze_end only used for debugging
	//HookEvent("round_freeze_end", Event_RoundFreezeEnd)
	g_iAccount = FindSendPropOffs("CCSPlayer", "m_iAccount");
	g_offObserverTarget = FindSendPropOffs("CBasePlayer", "m_hObserverTarget")
	if(g_offObserverTarget == -1)
	{
		SetFailState("Expected to find the offset to m_hObserverTarget, couldn't.")
	}
	AddCommandListener(NewTarget, "spec_next")
	AddCommandListener(NewTarget, "spec_prev")
	CreateConVar("bot2player_version", PLUGIN_VERSION, "Bot2player (public) version", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_DONTRECORD)
	cvar_b2p_enabled = CreateConVar("bot2player_enabled", "1", "Enable the plugin?", FCVAR_PLUGIN, true, 0.0, true, 1.0)
	cvar_BotTakeOverStartingCost = CreateConVar("bot2player_price", "0", "Starting cost to take over a BOT (resets each map)", FCVAR_PLUGIN)
	cvar_BotTakeOverCostIncrement = CreateConVar("bot2player_increase", "0", "Amount to raise price each time a player takes over a BOT", FCVAR_PLUGIN)
	if (cvar_b2p_enabled == INVALID_HANDLE) 
	{
		new String:FailReason[256]
		Format(FailReason, sizeof(FailReason), "[%s] - cvar_b2p_enabled returned INVALID_HANDLE", PLUGIN_NAME)
		EpicFail(FailReason)
	}
	cvar_Round_Restart_Delay = FindConVar("mp_round_restart_delay")
	if (cvar_Round_Restart_Delay == INVALID_HANDLE) 
	{
		new String:FailReason[256]
		Format(FailReason, sizeof(FailReason), "[%s] - cvar_b2p_enabled returned INVALID_HANDLE", PLUGIN_NAME)
		EpicFail(FailReason)
	}
}
public OnConfigsExecuted()
{
	//based on 5.0 second mp_round_restart_delay:  4.6 just a hair early, 5.0 too late - 4.7 seems good - use mp_round_restart_delay - 0.3
	Round_Restart_Delay = GetConVarFloat(cvar_Round_Restart_Delay)
	Weapon_Strip_Delay = Round_Restart_Delay - 0.1
	b2pEnabled = GetConVarBool(cvar_b2p_enabled)
	BotTakeOverStartingCost = GetConVarInt(cvar_BotTakeOverStartingCost)
	BotTakeOverCostIncrement = GetConVarInt(cvar_BotTakeOverCostIncrement)
	HookConVarChange(cvar_b2p_enabled, cvar_b2p_enabledChange)
	HookConVarChange(cvar_Round_Restart_Delay, cvar_b2p_enabledChange)
	HookConVarChange(cvar_BotTakeOverStartingCost, CvarStartCostChange)
	HookConVarChange(cvar_BotTakeOverCostIncrement, CvarCostIncreaseChange)
}
public OnMapStart()
{
	for (new i = 1; i <= MAXPLAYERS; i++)
	{
		BotTakeverCost[i] = BotTakeOverStartingCost
		TeleportWarning[i] = 0
	}	
	gameround = 1
}
public Action:Event_RoundStart(Handle:Event, const String:name[], bool:dontBroadcast)
{
	for (new i = 1; i <= MaxClients; i++)
	{
		ClientSpecClient[i] = 0
		WrongTeamWarning[i] = 0
	}
}
public Action:Event_RoundEnd(Handle:Event, const String:name[], bool:dontBroadcast)
{
	for (new i = 1; i <= MaxClients; i++)
	{
		ClientSpecClient[i] = 0
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientObserver(i) && ClientTookover[i])
		{
			/*if (IsClientConnected(i))
			{
				PrintCenterText(i, "Since you took over a BOT this last round, you get teleported")
				TeleportWarning[i] = 1
				new Float:iTargetOrigin[3]
				iTargetOrigin[0] = 0.0
				iTargetOrigin[1] = 0.0
				iTargetOrigin[2] = 0.0
				NormalizeVector(iTargetOrigin, iTargetOrigin)
				TeleportEntity(i, iTargetOrigin, NULL_VECTOR, NULL_VECTOR)
			}*/
			CreateTimer(Weapon_Strip_Delay, StripWeapons, GetClientUserId(i))
		}
		ClientTookover[i] = 0
		WrongTeamWarning[i] = 0
	}
	gameround++
}
public Action:Event_RoundFreezeEnd(Handle:Event, const String:name[], bool:dontBroadcast)
{
	//This entire routine is for debugging only
	PrintToServer("Round %i -----------------------------------------------------------------------", gameround)
	for (new i = 1; i <= MaxClients; i++)
	{
		if(!IsClientConnected(i) || !IsClientInGame(i) || IsClientObserver(i)) continue
		new TempWeapon[5]
		for (new ii = 0; ii <= 4; ii++)
		{
			TempWeapon[ii] = Client_GetWeaponBySlot(i, ii)
			if (TempWeapon[ii] > -1) 
			{
				new String:Weapon[32]
				GetEdictClassname(TempWeapon[ii], Weapon, sizeof(Weapon))
				if (ii == 3)
				{
					new tnades = GetAllClientGrenades(i)
					if (tnades)
					{
						PrintToServer("Nade report for %N:", i)
						if (Nades[i][0]) PrintToServer("%i HE Nades", Nades[i][0])
						if (Nades[i][1]) PrintToServer("%i Flash Nades", Nades[i][1])
						if (Nades[i][2]) PrintToServer("%i Smoke Nades", Nades[i][2])
						PrintToServer ("Line 114 - Total = %i", tnades)
					}
				}
			}
		}
	}
}
public Action:OnPlayerRunCmd(iClient, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!IsClientConnected(iClient) || !(buttons & IN_USE) || IsPlayerAlive(iClient) || !b2pEnabled || !IsClientObserver(iClient)) return Plugin_Continue
	new iTarget = GetEntPropEnt(iClient, Prop_Send, "m_hObserverTarget")
	new ClientCash = GetMoney(iClient)
	if (IsValidClient(iTarget) && IsFakeClient(iTarget) && GetClientTeam(iClient) == GetClientTeam(iTarget) && ClientCash >= BotTakeverCost[iClient])
	{
		//Get all of BOTs stats
		new Float:iTargetOrigin[3],	Float:iTargetAngles[3]
		GetClientAbsOrigin(iTarget, iTargetOrigin)
		GetClientAbsAngles(iTarget, iTargetAngles)
		new iTargetHealth = GetClientHealth(iTarget)
		new iTargetArmor = GetClientArmor(iTarget)
		iTargetActiveWeapon = Client_GetActiveWeapon(iTarget)
		for (new i = 0; i <= 1; i++)
		{
			iTargetWeapon[i] = Client_GetWeaponBySlot(iTarget, i)
			if (iTargetWeapon[i] > -1) 
			{
				Client_SetActiveWeapon(iTarget, iTargetWeapon[i])
				Client_GetActiveWeaponName(iTarget, iTargetActiveWeaponName, sizeof(iTargetActiveWeaponName))
				iTargetClip[i] = Weapon_GetPrimaryClip(iTargetWeapon[i])
				Client_GetWeaponPlayerAmmo(iTarget, iTargetActiveWeaponName, iTargetAmmo[i])		
			}
			else
			{
				iTargetClip[i] = 0
				iTargetAmmo[i] = 0
			}
		}
		//Check if target is alive one last time - fix for Known issue# 2
		if (!IsClientConnected(iTarget) || !IsValidClient(iTarget) || !IsPlayerAlive(iTarget))
		{
			PrintHintText(iClient, "The BOT you tried to take over is no longer available for take over")
			return Plugin_Continue
		}
		//Set all of humans stats, but not weapons		
		SetEntityHealth(iClient, iTargetHealth)
		Client_SetArmor(iClient, iTargetArmor)
		GetAllClientGrenades(iTarget)
		CreateTimer(0.05, Give_iTargetWeaponsTo_iClient, iClient)
		//Take control
		bHideDeath[iTarget] = true
		ClientTookover[iClient] = 1
		ClientSpecClient[iClient] = 0
		ClientCash = ClientCash - BotTakeverCost[iClient]
		SetMoney(iClient, ClientCash)
		BotTakeverCost[iClient] = BotTakeverCost[iClient] + BotTakeOverCostIncrement
		//check for last player on team alive
		new MyTeam = GetClientTeam(iClient)
		new TeamMatesAlive = 0
		for (new i = 1; i <= MaxClients; i++)
		{
			if (!IsClientConnected(i) || i == iClient) continue
			if (IsClientInGame(iClient) && IsClientInGame(i) && IsPlayerAlive(i) && MyTeam == GetClientTeam(i))
			{
				TeamMatesAlive++
			}
		}
		new Handle:NoEndRoundHandle = FindConVar("mp_ignore_round_win_conditions")
		if (TeamMatesAlive == 1)
		{
			SetConVarInt(NoEndRoundHandle, 1)
		}
		ForcePlayerSuicide(iTarget)
		CS_RespawnPlayer(iClient)
		TeleportEntity(iClient, iTargetOrigin, iTargetAngles, NULL_VECTOR)
		SetConVarInt(NoEndRoundHandle, 0)
		PrintToChatAll("%N took control of %N", iClient, iTarget)
		return Plugin_Handled
	}
	return Plugin_Continue
}
public GetAllClientGrenades(client)
{
	Nades[client][0] = 0
	Nades[client][1] = 0
	Nades[client][2] = 0
	new offsNades = FindDataMapOffs(client, "m_iAmmo") + (11 * 4);
	new granadesnr = GetEntData(client, offsNades)
	new lastgranadesnr = 0
	if (granadesnr > lastgranadesnr)
	{
		// HE Nades
		Nades[client][0] = granadesnr
		lastgranadesnr = granadesnr
	}
	offsNades += 4
	granadesnr += GetEntData(client, offsNades)
	if (granadesnr > lastgranadesnr)
	{
		// Flashbangs
		Nades[client][1] = granadesnr - lastgranadesnr
		lastgranadesnr = granadesnr
	}
	offsNades += 4
	granadesnr += GetEntData(client, offsNades)
	if (granadesnr > lastgranadesnr)
	{
		// Smoke Nades
		Nades[client][2] = granadesnr - lastgranadesnr
		lastgranadesnr = granadesnr
	}
	return granadesnr
}
public OnClientPostAdminCheck(client)
{
	BotTakeverCost[client] = BotTakeOverStartingCost
	ClientSpecClient[client] = 0
	ClientTookover[client] = 0
	WrongTeamWarning[client] = 0
}
public Action:StripWeapons(Handle:timer, any:UserID)
{
	new client = GetClientOfUserId(UserID)
	if (!client || !IsClientConnected(client)) return
	Client_RemoveAllWeapons(client)
	Client_GiveWeapon(client, "weapon_knife", true)
}
public Action:NewTarget(iClient, const String:cmd[], args)
{
	new iTarget = GetEntPropEnt(iClient, Prop_Send, "m_hObserverTarget")
	if (!b2pEnabled || !IsValidClient(iTarget) || !IsClientObserver(iClient)) return Plugin_Continue;
	CreateTimer(0.1, DisplayTakeOverMessage, iClient)
	return Plugin_Continue;
}
public Action:DisplayTakeOverMessage(Handle:timer, any:iClient)
{
	if (!b2pEnabled || !IsClientConnected(iClient)) return Plugin_Continue
	new ClientTeam = 0
	if (IsClientInGame(iClient)) ClientTeam = GetClientTeam(iClient)
	if (ClientTeam < 2) return Plugin_Continue
	new iTarget = -1
	iTarget = GetEntPropEnt(iClient, Prop_Send, "m_hObserverTarget")
	if (iTarget == -1) return Plugin_Continue
	decl String:BOTName[64]
	GetClientName(iTarget, BOTName, sizeof(BOTName))
	if (!IsValidClient(iTarget) || !IsClientObserver(iClient)) return Plugin_Continue
	ClientSpecClient[iClient] = iTarget
	new ClientCash = GetMoney(iClient)
	if (ClientCash >= BotTakeverCost[iClient])
	{
		if (IsFakeClient(iTarget))
		{
			if (ClientTeam == GetClientTeam(iTarget))
			{
				PrintHintText(iClient, "Press the Use key [default E] to take control of %s", BOTName)
				return Plugin_Continue
			}
			else
			{
				PrintHintText(iClient, "You can't take over BOTs that aren't on your team")
				return Plugin_Continue
			}
		}
		else
		{
			PrintHintText(iClient, "Spectate a BOT if you want to take over a BOT")
		}
	}
	else
	{
		PrintHintText(iClient, "You need $%i to take over any BOTs (the price increases each time you do)", BotTakeverCost[iClient])
		return Plugin_Continue
	}
	return Plugin_Continue
}
public Action:Event_PlayerDeath(Handle:Event, const String:name[], bool:dontBroadcast)
{
	if (!b2pEnabled) return Plugin_Continue
	new iClient = GetClientOfUserId(GetEventInt(Event, "userid"))
	if (!IsClientConnected(iClient)) return Plugin_Continue
	if (!IsFakeClient(iClient)) CreateTimer(6.75, DisplayTakeOverMessage, iClient)
	for (new i = 1; i <= MaxClients; i++)
	{
		if (i < GetClientCount(true))
		{
			new ClientCash = GetMoney(i)
			if (IsClientConnected(iClient) && IsClientConnected(i) && IsClientInGame(i) && IsClientObserver(i) && ClientSpecClient[i] == iClient && ClientCash >= BotTakeverCost[i])
			{
				PrintHintText(i, "%N died - You can't control dead BOTs", iClient)
				ClientSpecClient[i] = 0
			}
		}
	}
	if (!bHideDeath[iClient]) return Plugin_Continue
	CreateTimer(0.2, tDestroyRagdoll, iClient)
	return Plugin_Handled // Disable the killfeed notification for takeovers
}
public Action:tDestroyRagdoll(Handle:timer, any:iClient)
{
	new iRagdoll = GetEntPropEnt(iClient, Prop_Send, "m_hRagdoll")
	bHideDeath[iClient] = false
	if (iRagdoll < 0) return
	AcceptEntityInput(iRagdoll, "kill");
}
public Action:Give_iTargetWeaponsTo_iClient(Handle:timer, any:iClient)
{
	for (new i = 0; i <= 1; i++)
	{
		if (iTargetWeapon[i] != INVALID_ENT_REFERENCE)
		{
			Client_EquipWeapon(iClient, iTargetWeapon[i], false)
			Client_SetActiveWeapon(iClient, iTargetWeapon[i])
			Client_GetActiveWeaponName(iClient, iTargetActiveWeaponName, sizeof(iTargetActiveWeaponName))
			Client_SetWeaponClipAmmo(iClient, iTargetActiveWeaponName, iTargetClip[i])
			Client_SetWeaponPlayerAmmo(iClient, iTargetActiveWeaponName, iTargetAmmo[i])
		}
		Client_SetActiveWeapon(iClient, iTargetActiveWeapon)
	}
	if (Nades[iClient][0] > 0) Client_GiveWeapon(iClient, "weapon_hegrenade", false)
	if (Nades[iClient][1] > 0) Client_GiveWeapon(iClient, "weapon_flashbang", false)
	if (Nades[iClient][1] > 1) Client_GiveWeapon(iClient, "weapon_flashbang", false)
	if (Nades[iClient][2] > 0) Client_GiveWeapon(iClient, "weapon_smokegrenade", false)
}
public cvar_b2p_enabledChange(Handle:convar, const String:oldValue[], const String:newValue[])
{	
	b2pEnabled = GetConVarBool(cvar_b2p_enabled)
}
public CvarRoundRestartDelayChange(Handle:convar, const String:oldValue[], const String:newValue[])
{	
	Round_Restart_Delay = GetConVarFloat(cvar_Round_Restart_Delay)
	Weapon_Strip_Delay = Round_Restart_Delay - 0.1
}
public CvarStartCostChange(Handle:convar, const String:oldValue[], const String:newValue[])
{	
	BotTakeOverStartingCost = GetConVarInt(cvar_BotTakeOverStartingCost)
}
public CvarCostIncreaseChange(Handle:convar, const String:oldValue[], const String:newValue[])
{	
	BotTakeOverCostIncrement = GetConVarInt(cvar_BotTakeOverCostIncrement)
}
stock FindRagdollClosestToEntity(iEntity, Float:fLimit)
{
	new iSearch = -1,
	iReturn = -1;
	new Float:fLowest = -1.0,
	Float:fVectorDist,
	Float:fEntityPos[3],
	Float:fRagdollPos[3]
	if (!IsValidEntity(iEntity)) return iReturn;
	GetEntPropVector(iEntity, Prop_Send, "m_vecOrigin", fEntityPos);
	while ((iSearch = FindEntityByClassname(iSearch, "tf_ragdoll")) != -1)
	{
		GetEntPropVector(iSearch, Prop_Send, "m_vecRagdollOrigin", fRagdollPos);
		fVectorDist = GetVectorDistance(fEntityPos, fRagdollPos);
		if (fVectorDist < fLimit && (fVectorDist < fLowest || fLowest == -1.0))
		{
			fLowest = fVectorDist
			iReturn = iSearch
		}
	}
	return iReturn
}
stock bool:IsValidClient(iClient) 
{
	if (iClient <= 0 ||	iClient > MaxClients ||	!IsClientInGame(iClient)) return false
	return true
}
public GetMoney(client)
{
	if (!IsClientConnected(client) || !IsClientInGame(client)) return 0
	if (g_iAccount != -1)
	{
		return GetEntData(client, g_iAccount)
	}
	else
	{
		return 0
	}
}
public SetMoney(client, amount)
{
	if (!IsClientConnected(client) || !IsClientInGame(client)) return
	if (g_iAccount != -1)
	{
		SetEntData(client, g_iAccount, amount)
	}
}
public EpicFail(String:FailReason[])
{
	PrintToServer("[%s] - Fatal Error: %s", PLUGIN_NAME, FailReason)
	SetFailState("[%s] - Fatal Error: %s", PLUGIN_NAME, FailReason)
}
//End of