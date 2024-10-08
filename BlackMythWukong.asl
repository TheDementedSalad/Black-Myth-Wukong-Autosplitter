state("b1-Win64-Shipping"){}
state("b1-WinGDK-Shipping"){}

startup
{
    Assembly.Load(File.ReadAllBytes("Components/asl-help")).CreateInstance("Basic");
	vars.Helper.Settings.CreateFromXml("Components/BMWukong.Settings.xml");
	vars.Helper.GameName = "Black Myth: Wukong (2024)";
}

init
{
	IntPtr gWorld = vars.Helper.ScanRel(3, "48 8B 05 ???????? 48 3B C? 48 0F 44 C? 48 89 05 ???????? E8");
	IntPtr gEngine = vars.Helper.ScanRel(3, "48 89 05 ???????? 48 85 c9 74 ?? e8 ???????? 48 8d 4d");
	IntPtr Loading = vars.Helper.ScanRel(3, "48 89 35 ???????? 48 89 74 24 ?? e8 ???????? 48 8b 4c 24 ?? 8d 7e");
	
	vars.Helper["Level"] = vars.Helper.MakeString(gEngine, 0x910, 0x24);
	vars.Helper["Level"].FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull;
	
	vars.Helper["localPlayer"] = vars.Helper.Make<long>(gWorld, 0x1B8, 0x38, 0x0, 0x30);
	vars.Helper["localPlayer"].FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull;
	
	vars.Helper["isLoading"] = vars.Helper.Make<byte>(Loading, 0x240);
	
	vars.completedSplits = new HashSet<string>();
}

update
{
	//print(modules.First().ModuleMemorySize.ToString());
	
	vars.Helper.Update();
	vars.Helper.MapPointers();
}

onStart
{
	// This makes sure the timer always starts at 0.00
	timer.IsGameTimePaused = true;
	
	vars.completedSplits.Clear();
}

start
{
	return (current.Level == "HFS01/HFS01_PersistentLevel" || current.Level == "MGD/MGD_PersistentLevel") && current.isLoading == 0 && old.isLoading != 0;
}

split
{  
	string setting = "";
	
	if (!string.IsNullOrEmpty(current.Level) && current.Level != old.Level){
		setting = current.Level;
	}
	
	// Debug. Comment out before release.
	if (!string.IsNullOrEmpty(setting))
	vars.Log(setting);

	if (settings.ContainsKey(setting) && settings[setting] && vars.completedSplits.Add(setting)){
		return true;
	}
}

isLoading
{
	return current.isLoading != 0 || current.localPlayer == null || current.Level == "Startup/Startup_V2_P";
}

exit
{
	 //pauses timer if the game crashes
	timer.IsGameTimePaused = true;
}
