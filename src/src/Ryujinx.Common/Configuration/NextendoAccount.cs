using System;
using System.IO;

namespace Ryujinx.Common.Configuration
{
    /// <summary>
    /// Nextendo Network linked account. Written by the in-app "Connexion Nextendo
    /// Network" dialog, read by the Account service (ManagerServer) so the NEX
    /// login presents the account's PERSISTENT principal id (PID) instead of the
    /// 0xcafe stub — this is what makes "log in with your account = play online as
    /// you" work. Stored as a tiny key=value file (no JSON, trimming/AOT-safe).
    /// </summary>
    public static class NextendoAccount
    {
        private static readonly object _lock = new();
        private static bool _loaded;

        // ⚠️ Le PID et le jeton NEX sont stockes ici a l etat BRUT, et lus par les
        // proprietes publiques ci-dessous, qui les taisent en mode « serveur
        // personnalise ». La persistance ecrit les champs bruts, jamais les proprietes :
        // sinon enregistrer pendant ce mode effacerait le compte du disque.
        private static ulong _pid;
        private static string _nexToken = "";

        /// <summary>Numero de compte Nextendo. Zero quand aucun compte n est utilisable,
        /// y compris parce que le mode « serveur personnalise » est actif.</summary>
        public static ulong Pid => NextendoServerOverride.HorsNextendo ? 0 : _pid;

        public static string Username { get; private set; } = "";
        public static string FriendCode { get; private set; } = "";

        /// <summary>
        /// Le jeton signe qui prouve l identite du compte.
        ///
        /// ⚠️ IL NE DOIT JAMAIS SORTIR EN MODE « SERVEUR PERSONNALISE ». Le jeu le
        /// recopie dans le login NEX (claim « nnex ») : sans cette garde, se connecter au
        /// serveur d un inconnu lui livrerait un jeton signe valable sur NOS serveurs.
        /// </summary>
        public static string NexToken => NextendoServerOverride.HorsNextendo ? "" : _nexToken;

        private static bool _isGuest;

        /// <summary>True when the linked identity is a no-account GUEST profile (created by
        /// the beta quick-start via /api/guest) rather than a full registered account. A guest
        /// has a real persistent PID/friend code (online, friends and sync all work) but no
        /// e-mail/password; it can be renamed freely and later upgraded to a full account.</summary>
        public static bool IsGuest
        {
            get { EnsureLoaded(); return _isGuest; }
        }

        private static string _profileUserId = "";

        /// <summary>The Ryujinx user-profile UserId bound to this Nextendo account, so
        /// we reuse the same local profile instead of creating duplicates on each login.</summary>
        public static string ProfileUserId
        {
            get { EnsureLoaded(); return _profileUserId; }
        }

        private static string _miiData = "";

        /// <summary>Base64 of the account's Mii (Switch StoreData, 0x44 bytes), mirrored
        /// locally so the exact same Mii can be removed from the Mii database on logout.</summary>
        public static string MiiData
        {
            get { EnsureLoaded(); return _miiData; }
        }

        /// <summary>
        /// Le compte est-il utilisable MAINTENANT ?
        ///
        /// ⚠️ Le mode « serveur personnalisé » rend ceci faux sans effacer quoi que ce soit :
        /// le compte reste sur le disque et revient dès qu'on décoche la case. C'est ICI que
        /// la coupure est faite, et pas dans chaque appelant, parce que tout ce qui touche à
        /// Nextendo passe déjà par cette question — synchronisation des sauvegardes, amis,
        /// présence, historique, identité NEX présentée au jeu. Une coupure éparpillée aurait
        /// laissé passer celui qu'on aurait oublié.
        /// </summary>
        public static bool IsLinked
        {
            get
            {
                if (NextendoServerOverride.HorsNextendo)
                {
                    return false;
                }

                EnsureLoaded();

                return _pid != 0;
            }
        }

        /// <summary>Runtime-only (not persisted): set true at game launch when the running
        /// game is a Nextendo title on an UNSUPPORTED version. While true, the NEX login
        /// presents the anonymous stub instead of the account PID, so the gated server
        /// refuses online — enforcing the required game version.</summary>
        public static bool OnlineBlocked { get; set; }

        private static string FilePath
        {
            get
            {
                try
                {
                    string dir = AppDataManager.BaseDirPath;
                    if (string.IsNullOrEmpty(dir))
                    {
                        dir = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
                    }

                    return string.IsNullOrEmpty(dir) ? null : Path.Combine(dir, "nextendo_account.txt");
                }
                catch
                {
                    return null;
                }
            }
        }

        private static void EnsureLoaded()
        {
            lock (_lock)
            {
                if (_loaded)
                {
                    return;
                }

                _loaded = true;

                try
                {
                    string path = FilePath;
                    if (string.IsNullOrEmpty(path) || !File.Exists(path))
                    {
                        return;
                    }

                    foreach (string line in File.ReadAllLines(path))
                    {
                        int eq = line.IndexOf('=');
                        if (eq <= 0)
                        {
                            continue;
                        }

                        string key = line[..eq].Trim();
                        string val = line[(eq + 1)..].Trim();

                        switch (key)
                        {
                            case "pid": ulong.TryParse(val, out ulong p); _pid = p; break;
                            case "username": Username = val; break;
                            case "friend_code": FriendCode = val; break;
                            case "nex_token": _nexToken = val; break;
                            case "profile_user_id": _profileUserId = val; break;
                            case "mii_data": _miiData = val; break;
                            case "is_guest": _isGuest = val == "1" || val.Equals("true", StringComparison.OrdinalIgnoreCase); break;
                        }
                    }
                }
                catch
                {
                    // Corrupt/unreadable file -> treat as not linked.
                    _pid = 0;
                }
            }
        }

        public static void Save(ulong pid, string username, string friendCode, string nexToken, bool isGuest = false)
        {
            lock (_lock)
            {
                EnsureLoaded(); // preserve an existing profile binding for the same account
                // Comparaison sur le champ BRUT : la propriete Pid rend 0 en mode « serveur
                // personnalise », ce qui ferait croire a un changement de compte et delierait
                // le profil local a tort.
                if (pid != _pid)
                {
                    // different account -> unbind the previous local profile + Mii
                    _profileUserId = "";
                    _miiData = "";
                }
                _pid = pid;
                Username = username ?? "";
                FriendCode = friendCode ?? "";
                _nexToken = nexToken ?? "";
                _isGuest = isGuest;
                _loaded = true;
                WriteFileLocked();
            }
        }

        /// <summary>Binds the Ryujinx user-profile created/used for this account.</summary>
        public static void SetProfileUserId(string userId)
        {
            lock (_lock)
            {
                EnsureLoaded();
                _profileUserId = userId ?? "";
                WriteFileLocked();
            }
        }

        /// <summary>Mirrors the account's Mii (base64 StoreData) locally for logout removal.</summary>
        public static void SetMiiData(string miiData)
        {
            lock (_lock)
            {
                EnsureLoaded();
                _miiData = miiData ?? "";
                WriteFileLocked();
            }
        }

        private static void WriteFileLocked()
        {
            try
            {
                string path = FilePath;
                if (string.IsNullOrEmpty(path))
                {
                    return;
                }

                // ⚠️ Les champs BRUTS, jamais les propriétés. Pid et NexToken se taisent en mode
                // « serveur personnalisé » : les écrire ici réécrirait le fichier avec pid=0 et un
                // jeton vide, c'est-à-dire DÉTRUIRAIT le compte sur le disque — au premier
                // SetProfileUserId ou SetMiiData venu, alors que l'utilisateur voulait seulement
                // jouer ailleurs un moment.
                File.WriteAllText(path,
                    $"pid={_pid}\nusername={Username}\nfriend_code={FriendCode}\nnex_token={_nexToken}\nprofile_user_id={_profileUserId}\nmii_data={_miiData}\nis_guest={(_isGuest ? "1" : "0")}\n");
            }
            catch
            {
                // Best effort; the in-memory values still apply this session.
            }
        }

        public static void Clear()
        {
            lock (_lock)
            {
                _pid = 0;
                Username = "";
                FriendCode = "";
                _nexToken = "";
                _profileUserId = "";
                _miiData = "";
                _isGuest = false;
                _loaded = true;

                try
                {
                    string path = FilePath;
                    if (!string.IsNullOrEmpty(path) && File.Exists(path))
                    {
                        File.Delete(path);
                    }
                }
                catch
                {
                    // ignore
                }
            }
        }

        public static void Reload()
        {
            lock (_lock)
            {
                _loaded = false;
                EnsureLoaded();
            }
        }
    }
}
