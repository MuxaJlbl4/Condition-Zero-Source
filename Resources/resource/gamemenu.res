"GameMenu"
{
	"0"
	{
		"label"			"#GameUI_GameMenu_ResumeGame"
		"command"		"ResumeGame"
		"OnlyInGame"	"1"
	}
	"1"
	{
		"label"			"#Career_EndRound"
		"command"		"engine cz_skip; gamemenucommand resumegame"
		"OnlyInGame"	"1"
	}
	"2"
	{
		"label"			"#GameUI_GameMenu_Disconnect"
		"command"		"Disconnect"
		"OnlyInGame"	"1"
	}
	"3"
	{
		"label"			""
		"command"		""
		"OnlyInGame"	"1"
	}
	"4"
	{
		"label"			"#Career_ActiveTasks"
		"command"		"engine cz_list; gamemenucommand resumegame"
		"OnlyInGame"	"1"
	}
	"5"
	{
		"label"			""
		"command"		""
		"OnlyInGame"	"1"
	}
	"6"
	{
		"label"			"#Career_NewGame"
		"command"		"OpenBonusMapsDialog"
	}
	"7"
	{
		"label"			"#Career_Random"
		"command"		"OpenCreateMultiplayerGameDialog"
	}
	"8"
	{
		"label"			""
		"command"		""
	}
	"9"
	{
		"label"			"#GameUI_GameMenu_FindServers"
		"command"		"OpenServerBrowser"
	}
	"10"
	{
		"label"			"#GameUI_GameMenu_Achievements"
		"command"		"OpenCSAchievementsDialog"
	}
	"11"
	{
		"label"			"#GameUI_GameMenu_Options"
		"command"		"OpenOptionsDialog"
	}
	"12"
	{
		"label"			"#GameUI_GameMenu_Quit"
		"command"		"Quit"
	}
}

