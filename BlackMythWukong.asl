state("b1-Win64-Shipping"){}
state("b1-WinGDK-Shipping"){}

startup
{
    string componentDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Components");
    Assembly.Load(File.ReadAllBytes(Path.Combine(componentDir, "asl-help"))).CreateInstance("Basic");
    vars.Helper.Settings.CreateFromXml(Path.Combine(componentDir, "BMWukong.Settings.xml"));
    vars.Helper.GameName = "Black Myth: Wukong (2024)";
}

init
{
    IntPtr gEngine = vars.Helper.ScanRel(3, "48 89 05 ???????? 48 85 c9 74 ?? e8 ???????? 48 8d 4d");
    IntPtr Loading = vars.Helper.ScanRel(3, "48 89 35 ???????? 48 89 74 24 ?? e8 ???????? 48 8b 4c 24 ?? 8d 7e");

    vars.Helper["Level"] = vars.Helper.MakeString(gEngine, 0x910, 0x24);
    vars.Helper["Level"].FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull;

    vars.Helper["localPlayer"] = vars.Helper.Make<long>(gEngine, 0xDB8, 0x38, 0x0, 0x30);
    vars.Helper["localPlayer"].FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull;

    vars.Helper["isLoading"] = vars.Helper.Make<byte>(Loading, 0x240);

    vars.completedSplits = new HashSet<string>();
    vars.unlockedBosses = new HashSet<int>();
    vars.deadBosses = new HashSet<string>();
    vars.achievementStates = new Dictionary<int, string>();
    vars.kingRequirements = new HashSet<int>();
    vars.kingIds = new HashSet<int>(new int[] {
        103001, 103004, 103005, 103006, 103007,
        203004, 202005, 202002, 203006, 203005, 213001,
        303001, 303002, 302001, 302004, 303004,
        403003, 803001, 803002, 402012, 403007,
        503001, 503003, 503004, 703001, 603001
    });
    vars.eliteRequirements = new HashSet<int>();
    vars.eliteIds = new HashSet<int>(new int[] {
        102004, 102001, 102003, 202001, 202028, 203001, 203002, 202003, 202007, 202004,
        203003, 203007, 202006, 302009, 302013, 302002, 302003, 300001, 302010, 302007,
        302008, 301002, 302015, 302016, 403004, 403001, 403005, 400001, 403006, 400002,
        402014, 402001, 402010, 402009, 402015, 402007, 502003, 502001, 502004, 502005,
        502015, 502008, 502009, 502014, 502006, 602009, 602006, 602007, 103003, 602002,
        602004, 602005, 602003, 602008, 302014
    });
    vars.pendingBossSplits = new Queue<string>();
    vars.savePath = null;
    vars.lastSaveWrite = 0L;
    vars.lastSaveLength = -1L;
    vars.nextSaveSearch = 0L;
    vars.nextSaveLog = 0L;
    vars.gameExePath = "";
    vars.saveReady = false;

    // Minimal Protobuf reader. The game stores the archive payload in field 2
    // of the outer ArchiveFile message and XORs it with this 8-byte key.
    vars.ReadVarint = (Func<byte[], int[], int>) ((buf, ptr) =>
    {
        int value = 0;
        int shift = 0;
        while (true)
        {
            byte b = buf[ptr[0]++];
            value |= (b & 0x7F) << shift;
            if ((b & 0x80) == 0) return value;
            shift += 7;
        }
    });

    vars.GetMessageField = (Func<byte[], int, byte[]>) ((buf, targetField) =>
    {
        if (buf == null) return null;
        int[] pos = new int[] { 0 };
        while (pos[0] < buf.Length)
        {
            int key = ((Func<byte[], int[], int>)vars.ReadVarint)(buf, pos);
            int field = key >> 3;
            int wire = key & 7;
            if (wire == 2)
            {
                int len = ((Func<byte[], int[], int>)vars.ReadVarint)(buf, pos);
                if (field == targetField)
                {
                    byte[] value = new byte[len];
                    Array.Copy(buf, pos[0], value, 0, len);
                    return value;
                }
                pos[0] += len;
            }
            else if (wire == 0) { ((Func<byte[], int[], int>)vars.ReadVarint)(buf, pos); }
            else if (wire == 1) { pos[0] += 8; }
            else if (wire == 5) { pos[0] += 4; }
            else { return null; }
        }
        return null;
    });

    vars.ExtractPayload = (Func<byte[], byte[]>) ((bytes) =>
    {
        if (bytes == null) return null;
        int[] pos = new int[] { 0 };
        while (pos[0] < bytes.Length)
        {
            int key = ((Func<byte[], int[], int>)vars.ReadVarint)(bytes, pos);
            int field = key >> 3;
            int wire = key & 7;
            if (wire == 2)
            {
                int len = ((Func<byte[], int[], int>)vars.ReadVarint)(bytes, pos);
                if (field == 2)
                {
                    byte[] payload = new byte[len];
                    Array.Copy(bytes, pos[0], payload, 0, len);
                    byte[] keyBytes = new byte[] { 0x7B, 0x5C, 0xDA, 0x91, 0x3E, 0xFC, 0xDA, 0x37 };
                    for (int i = 0; i < payload.Length; i++)
                    {
                        payload[i] ^= keyBytes[i % keyBytes.Length];
                    }
                    return payload;
                }
                pos[0] += len;
            }
            else if (wire == 0) { ((Func<byte[], int[], int>)vars.ReadVarint)(bytes, pos); }
            else if (wire == 1) { pos[0] += 8; }
            else if (wire == 5) { pos[0] += 4; }
            else { return null; }
        }
        return null;
    });

    // Path: FUStBEDArchivesData(1) -> RoleData(1) -> RoleDataCS(8)
    //       -> RoleCollection / repeated MonsterCollectionList(1)
    //       -> MonsterCollection{ Id(1), PortraitStatus(4) }
    vars.GetUnlockedBosses = (Func<byte[], HashSet<int>>) ((data) =>
    {
        HashSet<int> result = new HashSet<int>();
        if (data == null) return result;

        byte[] roleData = ((Func<byte[], int, byte[]>)vars.GetMessageField)(data, 1);
        if (roleData == null) return result;
        byte[] roleCs = ((Func<byte[], int, byte[]>)vars.GetMessageField)(roleData, 1);
        if (roleCs == null) return result;
        byte[] collection = ((Func<byte[], int, byte[]>)vars.GetMessageField)(roleCs, 8);
        if (collection == null) return result;

        int[] pos = new int[] { 0 };
        while (pos[0] < collection.Length)
        {
            int key = ((Func<byte[], int[], int>)vars.ReadVarint)(collection, pos);
            int field = key >> 3;
            int wire = key & 7;
            if (wire == 2)
            {
                int len = ((Func<byte[], int[], int>)vars.ReadVarint)(collection, pos);
                if (field == 1)
                {
                    byte[] monster = new byte[len];
                    Array.Copy(collection, pos[0], monster, 0, len);
                    int monsterId = 0;
                    bool portraitUnlocked = false;
                    int[] monsterPos = new int[] { 0 };
                    while (monsterPos[0] < monster.Length)
                    {
                        int monsterKey = ((Func<byte[], int[], int>)vars.ReadVarint)(monster, monsterPos);
                        int monsterField = monsterKey >> 3;
                        int monsterWire = monsterKey & 7;
                        if (monsterWire == 0)
                        {
                            int value = ((Func<byte[], int[], int>)vars.ReadVarint)(monster, monsterPos);
                            if (monsterField == 1) monsterId = value;
                        }
                        else if (monsterWire == 2)
                        {
                            int valueLen = ((Func<byte[], int[], int>)vars.ReadVarint)(monster, monsterPos);
                            if (monsterField == 4 && valueLen > 0) portraitUnlocked = true;
                            monsterPos[0] += valueLen;
                        }
                        else if (monsterWire == 1) { monsterPos[0] += 8; }
                        else if (monsterWire == 5) { monsterPos[0] += 4; }
                        else { break; }
                    }
                    if (monsterId != 0 && portraitUnlocked) result.Add(monsterId);
                }
                else
                {
                    pos[0] += len;
                }
            }
            else if (wire == 0) { ((Func<byte[], int[], int>)vars.ReadVarint)(collection, pos); }
            else if (wire == 1) { pos[0] += 8; }
            else if (wire == 5) { pos[0] += 4; }
            else { break; }
        }
        return result;
    });

    // Path: FUStBEDArchivesData(2) -> LevelArchiveData(1)
    //       -> LevelBaseData(3) -> DeadUnitData{ Uid(1), ResetType(2) }
    vars.GetDeadBosses = (Func<byte[], HashSet<string>>) ((data) =>
    {
        HashSet<string> result = new HashSet<string>();
        if (data == null) return result;

        byte[] levelData = ((Func<byte[], int, byte[]>)vars.GetMessageField)(data, 2);
        if (levelData == null) return result;

        int[] p = new int[] { 0 };
        while (p[0] < levelData.Length)
        {
            int key = ((Func<byte[], int[], int>)vars.ReadVarint)(levelData, p);
            int field = key >> 3;
            int wire = key & 7;
            if (wire == 2)
            {
                int len = ((Func<byte[], int[], int>)vars.ReadVarint)(levelData, p);
                if (field == 1)
                {
                    byte[] levelBase = new byte[len];
                    Array.Copy(levelData, p[0], levelBase, 0, len);
                    int[] q = new int[] { 0 };
                    while (q[0] < levelBase.Length)
                    {
                        int subKey = ((Func<byte[], int[], int>)vars.ReadVarint)(levelBase, q);
                        int subField = subKey >> 3;
                        int subWire = subKey & 7;
                        if (subWire == 2)
                        {
                            int subLen = ((Func<byte[], int[], int>)vars.ReadVarint)(levelBase, q);
                            if (subField == 3)
                            {
                                byte[] deadUnit = new byte[subLen];
                                Array.Copy(levelBase, q[0], deadUnit, 0, subLen);
                                string uid = null;
                                int resetType = 0;
                                int[] r = new int[] { 0 };
                                while (r[0] < deadUnit.Length)
                                {
                                    int deadKey = ((Func<byte[], int[], int>)vars.ReadVarint)(deadUnit, r);
                                    int deadField = deadKey >> 3;
                                    int deadWire = deadKey & 7;
                                    if (deadWire == 0)
                                    {
                                        int deadValue = ((Func<byte[], int[], int>)vars.ReadVarint)(deadUnit, r);
                                        if (deadField == 2) resetType = deadValue;
                                    }
                                    else if (deadWire == 2)
                                    {
                                        int deadLen = ((Func<byte[], int[], int>)vars.ReadVarint)(deadUnit, r);
                                        if (deadField == 1) uid = System.Text.Encoding.UTF8.GetString(deadUnit, r[0], deadLen);
                                        r[0] += deadLen;
                                    }
                                    else if (deadWire == 1) { r[0] += 8; }
                                    else if (deadWire == 5) { r[0] += 4; }
                                    else { break; }
                                }
                                if (!string.IsNullOrEmpty(uid) && (resetType == 1 || resetType == 2) && uid.StartsWith("UGuid."))
                                {
                                    result.Add(uid);
                                }
                            }
                            else
                            {
                                q[0] += subLen;
                            }
                        }
                        else if (subWire == 0) { ((Func<byte[], int[], int>)vars.ReadVarint)(levelBase, q); }
                        else if (subWire == 1) { q[0] += 8; }
                        else if (subWire == 5) { q[0] += 4; }
                        else { break; }
                    }
                }
                else
                {
                    p[0] += len;
                }
            }
            else if (wire == 0) { ((Func<byte[], int[], int>)vars.ReadVarint)(levelData, p); }
            else if (wire == 1) { p[0] += 8; }
            else if (wire == 5) { p[0] += 4; }
            else { break; }
        }
        return result;
    });

    // Path: FUStBEDArchivesData(1) -> RoleData(1) -> RoleDataCS(10)
    //       -> RoleAchievement(3) -> AchievementOne
    vars.GetAchievementStates = (Func<byte[], Dictionary<int, string>>) ((data) =>
    {
        Dictionary<int, string> result = new Dictionary<int, string>();
        if (data == null) return result;

        byte[] roleData = ((Func<byte[], int, byte[]>)vars.GetMessageField)(data, 1);
        if (roleData == null) return result;
        byte[] roleCs = ((Func<byte[], int, byte[]>)vars.GetMessageField)(roleData, 1);
        if (roleCs == null) return result;
        byte[] achievementRoot = ((Func<byte[], int, byte[]>)vars.GetMessageField)(roleCs, 10);
        if (achievementRoot == null) return result;

        int[] p = new int[] { 0 };
        while (p[0] < achievementRoot.Length)
        {
            int key = ((Func<byte[], int[], int>)vars.ReadVarint)(achievementRoot, p);
            int field = key >> 3;
            int wire = key & 7;
            if (wire == 2)
            {
                int len = ((Func<byte[], int[], int>)vars.ReadVarint)(achievementRoot, p);
                if (field == 3)
                {
                    byte[] achievement = new byte[len];
                    Array.Copy(achievementRoot, p[0], achievement, 0, len);
                    int achievementId = 0;
                    bool isComplete = false;
                    List<int> requirements = new List<int>();
                    int[] q = new int[] { 0 };
                    while (q[0] < achievement.Length)
                    {
                        int achievementKey = ((Func<byte[], int[], int>)vars.ReadVarint)(achievement, q);
                        int achievementField = achievementKey >> 3;
                        int achievementWire = achievementKey & 7;
                        if (achievementWire == 0)
                        {
                            int value = ((Func<byte[], int[], int>)vars.ReadVarint)(achievement, q);
                            if (achievementField == 2) requirements.Add(value);
                            else if (achievementField == 3) isComplete = value != 0;
                        }
                        else if (achievementWire == 2)
                        {
                            int valueLen = ((Func<byte[], int[], int>)vars.ReadVarint)(achievement, q);
                            if (achievementField == 1)
                            {
                                int[] c = new int[] { q[0] };
                                int end = q[0] + valueLen;
                                while (c[0] < end)
                                {
                                    int configKey = ((Func<byte[], int[], int>)vars.ReadVarint)(achievement, c);
                                    int configField = configKey >> 3;
                                    int configWire = configKey & 7;
                                    if (configWire == 0)
                                    {
                                        int configValue = ((Func<byte[], int[], int>)vars.ReadVarint)(achievement, c);
                                        if (configField == 1) achievementId = configValue;
                                    }
                                    else if (configWire == 2) { int configLen = ((Func<byte[], int[], int>)vars.ReadVarint)(achievement, c); c[0] += configLen; }
                                    else if (configWire == 1) { c[0] += 8; }
                                    else if (configWire == 5) { c[0] += 4; }
                                    else { break; }
                                }
                            }
                            else if (achievementField == 2)
                            {
                                int[] r = new int[] { q[0] };
                                int end = q[0] + valueLen;
                                while (r[0] < end)
                                {
                                    requirements.Add(((Func<byte[], int[], int>)vars.ReadVarint)(achievement, r));
                                }
                            }
                            q[0] += valueLen;
                        }
                        else if (achievementWire == 1) { q[0] += 8; }
                        else if (achievementWire == 5) { q[0] += 4; }
                        else { break; }
                    }
                    if (achievementId != 0)
                    {
                        string requirementText = "";
                        foreach (int requirement in requirements)
                        {
                            if (requirementText.Length > 0) requirementText += ",";
                            requirementText += requirement;
                        }
                        result[achievementId] = (isComplete ? "1" : "0") + "|" + requirementText;
                    }
                }
                else
                {
                    p[0] += len;
                }
            }
            else if (wire == 0) { ((Func<byte[], int[], int>)vars.ReadVarint)(achievementRoot, p); }
            else if (wire == 1) { p[0] += 8; }
            else if (wire == 5) { p[0] += 4; }
            else { break; }
        }
        return result;
    });

    vars.GetRequirementIds = (Func<string, HashSet<int>>) ((state) =>
    {
        HashSet<int> result = new HashSet<int>();
        if (string.IsNullOrEmpty(state)) return result;
        int separator = state.IndexOf('|');
        if (separator < 0 || separator + 1 >= state.Length) return result;
        string[] parts = state.Substring(separator + 1).Split(',');
        foreach (string part in parts)
        {
            int value;
            if (int.TryParse(part, out value)) result.Add(value);
        }
        return result;
    });

    vars.Log = (Action<string>) ((message) =>
    {
        try
        {
            string logDirectory = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Logs");
            Directory.CreateDirectory(logDirectory);
            File.AppendAllText(Path.Combine(logDirectory, "BlackMythWukong.log"), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message + Environment.NewLine);
        }
        catch
        {
        }
    });

    ((Action<string>)vars.Log)("init: BlackMythWukong save splitter loaded");

    vars.FindSavePath = (Func<string, string>) ((gameExePath) =>
    {
        try
        {
            System.Collections.Generic.List<string> roots = new System.Collections.Generic.List<string>();

            string localRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "b1", "Saved", "SaveGames");
            if (Directory.Exists(localRoot)) roots.Add(localRoot);

            if (!string.IsNullOrEmpty(gameExePath))
            {
                string exeDir = Path.GetDirectoryName(gameExePath);
                if (!string.IsNullOrEmpty(exeDir))
                {
                    string savedDir = Path.GetFullPath(Path.Combine(exeDir, "..", "..", "Saved"));
                    string gameRoot = Path.Combine(savedDir, "SaveGames");
                    if (Directory.Exists(gameRoot)) roots.Add(gameRoot);
                }
            }

            string[] fallbackRoots = new string[]
            {
                @"E:\SteamLibrary\steamapps\common\BlackMythWukong\b1\Saved\SaveGames",
                @"C:\Program Files (x86)\Steam\steamapps\common\BlackMythWukong\b1\Saved\SaveGames"
            };
            foreach (string fallbackRoot in fallbackRoots)
            {
                if (Directory.Exists(fallbackRoot)) roots.Add(fallbackRoot);
            }

            string best = null;
            DateTime bestTime = DateTime.MinValue;
            foreach (string root in roots)
            {
                string[] files = Directory.GetFiles(root, "ArchiveSaveFile.*.sav", SearchOption.AllDirectories);
                foreach (string file in files)
                {
                    DateTime fileTime = File.GetLastWriteTimeUtc(file);
                    if (best == null || fileTime > bestTime)
                    {
                        best = file;
                        bestTime = fileTime;
                    }
                }
            }
            return best;
        }
        catch (Exception ex)
        {
            ((Action<string>)vars.Log)("FindSavePath error: " + ex.Message);
            return null;
        }
    });
}

update
{
    vars.Helper.Update();
    vars.Helper.MapPointers();

    if (!string.IsNullOrEmpty(vars.savePath) && !File.Exists(vars.savePath))
    {
        vars.savePath = null;
        vars.nextSaveSearch = 0L;
    }

    if (DateTime.UtcNow.Ticks >= ((long)vars.nextSaveSearch))
    {
        string gameExePath = "";
        try
        {
            if (game != null) gameExePath = game.MainModule.FileName;
        }
        catch
        {
        }
        if (!string.IsNullOrEmpty(gameExePath)) vars.gameExePath = gameExePath;

        string detectedSavePath = ((Func<string, string>)vars.FindSavePath)(gameExePath);
        vars.nextSaveSearch = DateTime.UtcNow.AddSeconds(10).Ticks;
        if (!string.IsNullOrEmpty(detectedSavePath) && detectedSavePath != vars.savePath)
        {
            ((Action<string>)vars.Log)("save path: " + detectedSavePath);
            vars.savePath = detectedSavePath;
            vars.saveReady = false;
            vars.lastSaveWrite = 0L;
            vars.lastSaveLength = -1L;
            vars.unlockedBosses = new HashSet<int>();
            vars.deadBosses = new HashSet<string>();
            vars.achievementStates = new Dictionary<int, string>();
            vars.kingRequirements = new HashSet<int>();
            vars.eliteRequirements = new HashSet<int>();
            ((Queue<string>)vars.pendingBossSplits).Clear();
        }
        else if (string.IsNullOrEmpty(detectedSavePath) && DateTime.UtcNow.Ticks >= ((long)vars.nextSaveLog))
        {
            ((Action<string>)vars.Log)("save path not found. gameExePath=" + gameExePath);
            vars.nextSaveLog = DateTime.UtcNow.AddMinutes(1).Ticks;
        }
    }

    if (!string.IsNullOrEmpty(vars.savePath))
    {
        try
        {
            long writeTicks = File.GetLastWriteTimeUtc(vars.savePath).Ticks;
            long fileLength = new FileInfo(vars.savePath).Length;
            if (writeTicks != ((long)vars.lastSaveWrite) || fileLength != ((long)vars.lastSaveLength))
            {
                vars.lastSaveWrite = writeTicks;
                vars.lastSaveLength = fileLength;

                byte[] saveBytes = File.ReadAllBytes(vars.savePath);
                byte[] payload = ((Func<byte[], byte[]>)vars.ExtractPayload)(saveBytes);
                HashSet<int> unlocked = ((Func<byte[], HashSet<int>>)vars.GetUnlockedBosses)(payload);
                HashSet<string> deadBosses = ((Func<byte[], HashSet<string>>)vars.GetDeadBosses)(payload);
                Dictionary<int, string> achievements = ((Func<byte[], Dictionary<int, string>>)vars.GetAchievementStates)(payload);
                string kingAchievementState = achievements.ContainsKey(7403) ? achievements[7403] : null;
                HashSet<int> kingRequirements = ((Func<string, HashSet<int>>)vars.GetRequirementIds)(kingAchievementState);
                string eliteAchievementState = achievements.ContainsKey(7402) ? achievements[7402] : null;
                HashSet<int> eliteRequirements = ((Func<string, HashSet<int>>)vars.GetRequirementIds)(eliteAchievementState);
                if (unlocked != null && deadBosses != null && achievements != null)
                {
                    if (!((bool)vars.saveReady))
                    {
                        vars.unlockedBosses = unlocked;
                        vars.deadBosses = deadBosses;
                        vars.achievementStates = achievements;
                        vars.kingRequirements = kingRequirements;
                    vars.eliteRequirements = eliteRequirements;
                        vars.saveReady = true;
                    }
                    else
                    {
                        HashSet<int> oldEliteRequirements = (HashSet<int>)vars.eliteRequirements;
                        foreach (int eliteId in eliteRequirements)
                        {
                            if (!oldEliteRequirements.Contains(eliteId))
                            {
                                string eliteSettingId = "Boss_" + eliteId;
                                bool eliteEnabled = settings.ContainsKey(eliteSettingId) && settings[eliteSettingId];
                                ((Action<string>)vars.Log)("new elite unlock (7402): " + eliteId + " setting=" + eliteSettingId + " enabled=" + eliteEnabled);
                                if (eliteEnabled)
                                {
                                    ((Queue<string>)vars.pendingBossSplits).Enqueue(eliteSettingId);
                                }
                            }
                        }

                        HashSet<int> oldKingRequirements = (HashSet<int>)vars.kingRequirements;
                        foreach (int kingId in kingRequirements)
                        {
                            if (!oldKingRequirements.Contains(kingId))
                            {
                                string kingSettingId = "Boss_" + kingId;
                                bool kingEnabled = settings.ContainsKey(kingSettingId) && settings[kingSettingId];
                                ((Action<string>)vars.Log)("new king unlock (7403): " + kingId + " setting=" + kingSettingId + " enabled=" + kingEnabled);
                                if (kingEnabled)
                                {
                                    ((Queue<string>)vars.pendingBossSplits).Enqueue(kingSettingId);
                                }
                            }
                        }

                        HashSet<int> oldUnlocked = (HashSet<int>)vars.unlockedBosses;
                        foreach (int bossId in unlocked)
                        {
                            if (((HashSet<int>)vars.kingIds).Contains(bossId) || ((HashSet<int>)vars.eliteIds).Contains(bossId)) continue;
                            if (!oldUnlocked.Contains(bossId))
                            {
                                string settingId = "Boss_" + bossId;
                                bool enabled = settings.ContainsKey(settingId) && settings[settingId];
                                ((Action<string>)vars.Log)("new portrait unlock: " + bossId + " enabled=" + enabled);
                                if (enabled)
                                {
                                    ((Queue<string>)vars.pendingBossSplits).Enqueue(settingId);
                                }
                            }
                        }

                        HashSet<string> oldDeadBosses = (HashSet<string>)vars.deadBosses;
                        foreach (string uid in deadBosses)
                        {
                            if (!oldDeadBosses.Contains(uid))
                            {
                                string settingId = "Dead_" + uid;
                                bool enabled = settings.ContainsKey(settingId) && settings[settingId];
                                ((Action<string>)vars.Log)("new dead-unit: " + uid + " setting=" + settingId + " enabled=" + enabled);
                                if (enabled && vars.completedSplits.Add(settingId))
                                {
                                    ((Queue<string>)vars.pendingBossSplits).Enqueue(settingId);
                                }
                            }
                        }

                        Dictionary<int, string> oldAchievements = (Dictionary<int, string>)vars.achievementStates;
                        foreach (KeyValuePair<int, string> pair in achievements)
                        {
                            int achievementId = pair.Key;
                            string newState = pair.Value;
                            string oldState = null;
                            if (oldAchievements.ContainsKey(achievementId)) oldState = oldAchievements[achievementId];

                            if (oldState == null)
                            {
                                if (newState.StartsWith("1"))
                                {
                                    // ((Action<string>)vars.Log)("achievement complete(new): " + achievementId + " state=" + newState);
                                }
                                else
                                {
                                    // ((Action<string>)vars.Log)("achievement new: " + achievementId + " state=" + newState);
                                }
                            }
                            else if (oldState != newState)
                            {
                                if (newState.StartsWith("1") && !oldState.StartsWith("1"))
                                {
                                    // ((Action<string>)vars.Log)("achievement complete: " + achievementId + " state=" + newState + " old=" + oldState);
                                }
                                else
                                {
                                    // ((Action<string>)vars.Log)("achievement change: " + achievementId + " old=" + oldState + " new=" + newState);
                                }
                            }
                        }

                        vars.unlockedBosses = unlocked;
                        vars.deadBosses = deadBosses;
                        vars.achievementStates = achievements;
                        vars.kingRequirements = kingRequirements;
                    vars.eliteRequirements = eliteRequirements;
                    }
                }
            }
        }
        catch (Exception ex)
        {
            ((Action<string>)vars.Log)("update error: " + ex.Message);
        }
    }
}

onStart
{
    // Keep the timer at 0.00 and treat the current save state as the baseline.
    timer.IsGameTimePaused = true;
    vars.completedSplits.Clear();
    vars.pendingBossSplits = new Queue<string>();
    vars.unlockedBosses = new HashSet<int>();
    vars.deadBosses = new HashSet<string>();
    vars.achievementStates = new Dictionary<int, string>();
    vars.kingRequirements = new HashSet<int>();
    vars.eliteRequirements = new HashSet<int>();
    vars.saveReady = false;

    if (!string.IsNullOrEmpty(vars.savePath))
    {
        try
        {
            byte[] saveBytes = File.ReadAllBytes(vars.savePath);
            byte[] payload = ((Func<byte[], byte[]>)vars.ExtractPayload)(saveBytes);
            HashSet<int> currentUnlocked = ((Func<byte[], HashSet<int>>)vars.GetUnlockedBosses)(payload);
            HashSet<string> currentDead = ((Func<byte[], HashSet<string>>)vars.GetDeadBosses)(payload);
            Dictionary<int, string> currentAchievements = ((Func<byte[], Dictionary<int, string>>)vars.GetAchievementStates)(payload);
            string currentKingState = currentAchievements.ContainsKey(7403) ? currentAchievements[7403] : null;
            HashSet<int> currentKingRequirements = ((Func<string, HashSet<int>>)vars.GetRequirementIds)(currentKingState);
            string currentEliteState = currentAchievements.ContainsKey(7402) ? currentAchievements[7402] : null;
            HashSet<int> currentEliteRequirements = ((Func<string, HashSet<int>>)vars.GetRequirementIds)(currentEliteState);
            int completedAchievements = 0;
            foreach (KeyValuePair<int, string> pair in currentAchievements)
            {
                if (pair.Value.StartsWith("1")) completedAchievements++;
            }
            vars.unlockedBosses = currentUnlocked;
            vars.deadBosses = currentDead;
            vars.achievementStates = currentAchievements;
            vars.kingRequirements = currentKingRequirements;
            vars.eliteRequirements = currentEliteRequirements;
            vars.saveReady = true;
            ((Action<string>)vars.Log)("onStart baseline portraits=" + currentUnlocked.Count + " deadUnits=" + currentDead.Count + " achievements=" + currentAchievements.Count + " complete=" + completedAchievements + " kings=" + currentKingRequirements.Count + " elites=" + currentEliteRequirements.Count);
        }
        catch (Exception ex)
        {
            ((Action<string>)vars.Log)("onStart error: " + ex.Message);
        }
    }
}

start
{
    return (current.Level == "HFS01/HFS01_PersistentLevel" || current.Level == "MGD/MGD_PersistentLevel") && current.isLoading == 0 && old.isLoading != 0;
}

split
{
    Queue<string> pending = (Queue<string>)vars.pendingBossSplits;
    while (pending.Count > 0)
    {
        string bossSetting = pending.Dequeue();
        if (settings.ContainsKey(bossSetting) && settings[bossSetting])
        {
            ((Action<string>)vars.Log)("boss split: " + bossSetting);
            return true;
        }
    }

    // All boss triggers are now config-driven through the pending queue.
    return false;
}

isLoading
{
    return current.isLoading != 0 || current.localPlayer == null || current.Level == "Startup/Startup_V2_P";
}

exit
{
    // Pauses the timer if the game crashes.
    timer.IsGameTimePaused = true;
}
