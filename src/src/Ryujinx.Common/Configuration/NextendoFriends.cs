using Gommon;
using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text.Json;

namespace Ryujinx.Common.Configuration
{
    /// <summary>
    /// [Nextendo] Cached friend list for the in-game Switch <c>friend:</c> service. The HLE
    /// friends sysmodule (Ryujinx.Horizon) reads this so Mario Kart 8's "Amis/Adversaires"
    /// shows the player's Nextendo friends. Fetched (synchronously, cached ~10 s) from the
    /// account service using the persisted NEX token, so it works across the assembly
    /// boundary without referencing the UI project.
    /// </summary>
    public static class NextendoFriends
    {
        public readonly struct Entry
        {
            public readonly ulong Pid;
            public readonly string Name;
            // The friend's NSA id (nn::friends NetworkServiceAccountId). Splatoon 3 gets its friend
            // list from NPLN, which names each friend by nsa_id, then asks the console's LOCAL
            // friend: service for their details BY THAT SAME nsa_id. Keyed only by Pid we could
            // resolve none of them, and the in-game "Amis" screen stayed empty.
            public readonly ulong Nsa;
            // Statut de presence rapporte par le serveur de comptes (0 = hors ligne). Sans lui on
            // annoncait TOUS les amis « en train de jouer », ce qui est faux et pousse le jeu a
            // proposer de rejoindre des parties qui n'existent pas.
            public readonly int Status;
            // The friend's live S2 presence "AppField" (nn::friends AppKeyValueStorage, up to
            // 0xC0 bytes) relayed by the account server — encodes SessionId/Full/etc. so S2 sees
            // the friend as in a JOINABLE private battle. Empty when the friend isn't in a room.
            public readonly byte[] AppField;

            public Entry(ulong pid, string name, byte[] appField, ulong nsa = 0, int status = 0)
            {
                Pid = pid;
                Name = name;
                AppField = appField;
                Nsa = nsa;
                Status = status;
            }
        }

        private static readonly object _lock = new();
        private static List<Entry> _cache = new();
        private static long _lastFetchMs;
        private static int _refreshing;

        /// <summary>
        /// [Nextendo] Liste d'amis GARANTIE chaude, avec attente BORNEE.
        ///
        /// Get() ne bloque jamais et remplit en tache de fond — indispensable pour les jeux NEX, qui
        /// interrogent en boucle depuis le fil online : un blocage la-bas coupe les acquittements
        /// PRUDP et le serveur declare l'erreur de communication. Mais Splatoon 3, lui, demande sa
        /// liste UNE SEULE FOIS, tot (mesure : a 39 s de boot, cache encore vide) et repart avec
        /// zero ami sans jamais redemander. Pour ce cas precis on accepte une attente COURTE et
        /// plafonnee, jamais sur le chemin des jeux NEX.
        /// </summary>
        public static IReadOnlyList<Entry> GetWarm(int timeoutMs)
        {
            IReadOnlyList<Entry> list = Get(); // declenche le rafraichissement de fond si besoin
            if (list.Count > 0 || !NextendoAccount.IsLinked)
            {
                return list;
            }

            long deadline = Environment.TickCount64 + timeoutMs;
            while (Environment.TickCount64 < deadline)
            {
                System.Threading.Thread.Sleep(50);
                list = Get();
                if (list.Count > 0)
                {
                    break;
                }
            }

            return list;
        }

        public static IReadOnlyList<Entry> Get()
        {
            // NEVER block the caller. The in-game friend service runs on the game's online
            // thread; a synchronous HTTP fetch here stalls the game for up to several seconds,
            // so it stops acking NEX/PRUDP -> the server's retransmit times out -> "erreur de
            // communication" (connection killed). Return the cached list IMMEDIATELY and refresh
            // in the BACKGROUND when stale. The list populates within ~1s and the game polls
            // repeatedly, so it fills in without ever blocking.
            if (NextendoAccount.IsLinked
                && (_lastFetchMs == 0 || Environment.TickCount64 - _lastFetchMs > 10_000)
                && System.Threading.Interlocked.Exchange(ref _refreshing, 1) == 0)
            {
                System.Threading.Tasks.Task.Run(() =>
                {
                    try { Refresh(); }
                    finally { System.Threading.Interlocked.Exchange(ref _refreshing, 0); }
                });
            }

            lock (_lock)
            {
                return _cache;
            }
        }

        public static void Invalidate()
        {
            lock (_lock)
            {
                _cache = new List<Entry>();
                _lastFetchMs = 0;
            }
        }

        // [Nextendo] Photos de profil des amis, servies au service friend: LOCAL de la console
        // (GetFriendProfileImage, cmd 10110). Elles ne viennent pas de la liste d'amis — celle-ci ne
        // porte qu'une URL — mais de /api/avatar?pid=<pid>, qui rend un JPEG. On les recupere donc a
        // la demande, une seule fois par ami, et on garde le resultat (y compris l'echec, en tableau
        // vide) pour ne jamais re-solliciter le serveur sur le fil d'appel du jeu.
        private static readonly object _imgLock = new();
        private static readonly Dictionary<ulong, byte[]> _images = new();
        private static readonly HashSet<ulong> _imgFetching = new();

        /// <summary>
        /// Photo de profil d'un ami (JPEG), ou null tant qu'elle n'est pas arrivee. Ne bloque
        /// jamais : la recuperation part en tache de fond, comme la liste d'amis.
        /// </summary>
        public static byte[] ProfileImage(ulong pid)
        {
            if (pid == 0)
            {
                return null;
            }

            lock (_imgLock)
            {
                if (_images.TryGetValue(pid, out byte[] cached))
                {
                    return cached.Length > 0 ? cached : null;
                }

                if (!_imgFetching.Add(pid))
                {
                    return null; // deja en cours
                }
            }

            System.Threading.Tasks.Task.Run(() =>
            {
                byte[] data = System.Array.Empty<byte>();
                try
                {
                    string baseUrl = NextendoEndpoint.BaseUrl().TrimEnd('/');
                    using HttpRequestMessage req = new(HttpMethod.Get, baseUrl + "/api/avatar?pid=" + pid);
                    using HttpResponseMessage resp = _http.SendAsync(req).GetAwaiter().GetResult();
                    if (resp.IsSuccessStatusCode)
                    {
                        byte[] body = resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult();
                        // La console attend un JPEG : on ne sert que ce qui en est un (SOI ff d8).
                        if (body.Length > 2 && body[0] == 0xFF && body[1] == 0xD8)
                        {
                            data = body;
                        }
                    }
                }
                catch
                {
                    // reseau indisponible : on retient l'echec (tableau vide) plutot que de boucler
                }

                lock (_imgLock)
                {
                    _images[pid] = data;
                    _imgFetching.Remove(pid);
                }
            });

            return null;
        }

        /// <summary>Photo de profil avec attente BORNEE — meme raison que GetWarm.</summary>
        public static byte[] ProfileImageWarm(ulong pid, int timeoutMs)
        {
            byte[] img = ProfileImage(pid);
            if (img != null)
            {
                return img;
            }

            long deadline = Environment.TickCount64 + timeoutMs;
            while (Environment.TickCount64 < deadline)
            {
                System.Threading.Thread.Sleep(50);
                img = ProfileImage(pid);
                if (img != null)
                {
                    return img;
                }

                lock (_imgLock)
                {
                    if (_images.ContainsKey(pid))
                    {
                        return null; // resolu en echec, inutile d'attendre plus
                    }
                }
            }

            return null;
        }

        private static readonly object _nameLock = new();
        private static readonly Dictionary<ulong, string> _names = new();
        private static readonly HashSet<ulong> _nameFetching = new();

        /// <summary>
        /// Public display name of any player, friend or not (/api/names), cached like ProfileImage;
        /// waits at most timeoutMs for a first lookup. Null when unknown.
        /// </summary>
        public static string PublicName(ulong pid, int timeoutMs)
        {
            if (pid == 0)
            {
                return null;
            }

            lock (_nameLock)
            {
                if (_names.TryGetValue(pid, out string cached))
                {
                    return cached.Length > 0 ? cached : null;
                }

                if (_nameFetching.Add(pid))
                {
                    System.Threading.Tasks.Task.Run(() => FetchName(pid));
                }
            }

            long deadline = Environment.TickCount64 + timeoutMs;
            while (Environment.TickCount64 < deadline)
            {
                System.Threading.Thread.Sleep(50);
                lock (_nameLock)
                {
                    if (_names.TryGetValue(pid, out string name))
                    {
                        return name.Length > 0 ? name : null;
                    }
                }
            }

            return null;
        }

        private static void FetchName(ulong pid)
        {
            string name = "";
            try
            {
                string baseUrl = NextendoEndpoint.BaseUrl().TrimEnd('/');
                using HttpRequestMessage req = new(HttpMethod.Get, baseUrl + "/api/names?pids=" + pid);
                using HttpResponseMessage resp = _http.SendAsync(req).GetAwaiter().GetResult();
                if (resp.IsSuccessStatusCode)
                {
                    using JsonDocument doc = JsonDocument.Parse(resp.Content.ReadAsStringAsync().GetAwaiter().GetResult());
                    if (doc.RootElement.TryGetProperty("names", out JsonElement names)
                        && names.TryGetProperty(pid.ToString(), out JsonElement entry)
                        && entry.TryGetProperty("name", out JsonElement n))
                    {
                        name = n.GetString() ?? "";
                    }
                }
            }
            catch
            {
                // network unavailable: remember the miss rather than retry on the game's thread
            }

            lock (_nameLock)
            {
                _names[pid] = name;
                _nameFetching.Remove(pid);
            }
        }

        private static void Refresh()
        {
            try
            {
                if (string.IsNullOrEmpty(NextendoAccount.NexToken))
                {
                    return;
                }

                // [Nextendo] Une seule decision, dans NextendoEndpoint : elle choisit qui recoit le
                // jeton du compte pose juste en dessous.
                string baseUrl = NextendoEndpoint.BaseUrl();

                using HttpRequestMessage req = new(HttpMethod.Get, baseUrl.TrimEnd('/') + "/api/friends");
                req.Headers.Add("Authorization", "Bearer " + NextendoAccount.NexToken);
                using HttpResponseMessage resp = _http.SendAsync(req).GetAwaiter().GetResult();
                string json = resp.Content.ReadAsStringAsync().GetAwaiter().GetResult();

                List<Entry> list = new();
                using JsonDocument doc = JsonDocument.Parse(json);
                if (doc.RootElement.TryGetProperty("friends", out JsonElement arr) && arr.ValueKind == JsonValueKind.Array)
                {
                    foreach (JsonElement f in arr.EnumerateArray())
                    {
                        ulong pid = f.TryGetProperty("pid", out JsonElement p) ? p.GetUInt64() : 0;
                        string name = f.TryGetProperty("name", out JsonElement n) ? (n.GetString() ?? "") : "";
                        byte[] appField = null;
                        int status = 0;
                        if (f.TryGetProperty("presence", out JsonElement pres0) && pres0.ValueKind == JsonValueKind.Object
                            && pres0.TryGetProperty("status", out JsonElement st) && st.ValueKind == JsonValueKind.Number)
                        {
                            status = st.GetInt32();
                        }
                        if (f.TryGetProperty("presence", out JsonElement pres) && pres.ValueKind == JsonValueKind.Object
                            && pres.TryGetProperty("app_field", out JsonElement af) && af.ValueKind == JsonValueKind.String)
                        {
                            string b64 = af.GetString();
                            if (!string.IsNullOrEmpty(b64))
                            {
                                try { appField = Convert.FromBase64String(b64); } catch { appField = null; }
                            }
                        }
                        ulong nsa = 0;
                        if (f.TryGetProperty("nsa", out JsonElement nsaEl) && nsaEl.ValueKind == JsonValueKind.String)
                        {
                            _ = ulong.TryParse(nsaEl.GetString(), System.Globalization.NumberStyles.HexNumber,
                                System.Globalization.CultureInfo.InvariantCulture, out nsa);
                        }
                        if (pid != 0)
                        {
                            list.Add(new Entry(pid, name, appField, nsa, status));
                        }
                    }
                }

                lock (_lock)
                {
                    _cache = list;
                    _lastFetchMs = Environment.TickCount64;
                }
            }
            catch
            {
                // keep the stale cache on any failure
            }
        }

        private static string _lastKey;
        private static long _lastPublishMs;
        private static int _publishing;

        // ONE shared HttpClient for all background Nextendo calls. Creating a new HttpClient per
        // call leaks sockets (TIME_WAIT) and, combined with unbounded Task.Run, starves the thread
        // pool — which dropped the game's FPS. Shared client + single-flight + hard rate-limit fix it.
        private static readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(8) };

        // [Nextendo] État de présence UNIFIÉ : le status nn::friends + le blob de join S2 (appField)
        // + LE TITRE DU JEU COURANT (CurrentTitleId, posé par NextendoPresenceModule au lancement de
        // n'importe quel jeu). Ainsi les amis voient « joue à <jeu> » pour TOUT jeu (pas que S2), et
        // le blob de join S2 reste transporté quand on est en salon privé.
        public static volatile string CurrentTitleId = "";

        // [Nextendo] Détail du jeu courant venant de son PLAY REPORT (« Single Player », « Racing »…),
        // posé par NextendoRichPresence. N'existe QUE pour les jeux ayant une spec PlayReports (~13 :
        // MK8DX, SSBU, Odyssey, Zelda…) — chaque jeu émet un format propre, reversé titre par titre.
        // Vide pour tous les autres : les amis voient alors le nom du jeu seul, jamais un mode inventé.
        public static volatile string CurrentAppDetail = "";
        private static int _curStatus = 1;
        private static byte[] _curAppField = System.Array.Empty<byte>();

        /// <summary>[Nextendo] Chemin S2 (nn::friends UpdateUserPresence) : status + blob de join.</summary>
        public static void PublishPresence(int status, byte[] appField)
        {
            _curStatus = status;
            _curAppField = appField ?? System.Array.Empty<byte>();
            DoPublish();
        }

        /// <summary>[Nextendo] Chemin « jeu courant » (lancement/sortie/périodique) : le status découle
        /// du titre courant (en jeu = OnlinePlay, sinon Online au repos).</summary>
        public static void PublishGame()
        {
            _curStatus = string.IsNullOrEmpty(CurrentTitleId) ? 1 : 2;
            DoPublish();
        }

        private static System.Threading.Timer _presenceTimer;

        /// <summary>[Nextendo] Démarre la remontée de présence du JEU COURANT (n'importe quel jeu, pas
        /// que S2) : s'abonne au changement d'application (TitleIDs.CurrentApplication) pour poser le
        /// titre courant + publier, et rafraîchit périodiquement le TTL serveur (90s). Appelé une fois
        /// au démarrage de l'émulateur.</summary>
        public static void InitializePresence()
        {
            TitleIDs.CurrentApplication.Event += (_, e) =>
            {
                CurrentTitleId = e.NewValue.TryGet(out string tid) ? (tid ?? "") : "";

                // Le détail appartient au jeu qu'on quitte : sans ça, « Single Player » de Mario Kart
                // resterait collé au titre suivant jusqu'à ce qu'il émette son propre play report.
                CurrentAppDetail = "";

                PublishGame();
            };
            _presenceTimer = new System.Threading.Timer(_ => PublishGame(), null, 45000, 45000);
        }

        // Poste l'état de présence courant. HARD rate-limit (>=3s), SINGLE-FLIGHT, dédup 30s sur
        // (status|jeu|blob) — pour rafraîchir le TTL serveur (90s) tout en évitant le spam.
        private static void DoPublish()
        {
            if (!NextendoAccount.IsLinked || string.IsNullOrEmpty(NextendoAccount.NexToken))
            {
                return;
            }

            byte[] appField = _curAppField ?? System.Array.Empty<byte>();
            string appId = CurrentTitleId ?? "";
            string appDetail = CurrentAppDetail ?? "";
            int status = _curStatus;
            string appFieldB64 = Convert.ToBase64String(appField);

            // appDetail belongs in the dedup key: switching from "Single Player" to "Racing" keeps
            // the same status and title, and without it the change would be suppressed for 30s —
            // exactly the moment the detail is worth showing.
            string key = status + "|" + appId + "|" + appFieldB64 + "|" + appDetail;

            lock (_lock)
            {
                if (_lastPublishMs != 0 && Environment.TickCount64 - _lastPublishMs < 3000)
                {
                    return;
                }
                if (key == _lastKey && _lastPublishMs != 0 && Environment.TickCount64 - _lastPublishMs < 30000)
                {
                    return;
                }
                _lastKey = key;
                _lastPublishMs = Environment.TickCount64;
            }

            if (System.Threading.Interlocked.Exchange(ref _publishing, 1) == 1)
            {
                return;
            }

            string token = NextendoAccount.NexToken;

            // Serialized, not concatenated. app_field (base64) and app_id (hex) could never break
            // the JSON, but app_detail is free text straight out of a game's play report — a single
            // quote or backslash in it would corrupt the body. JsonSerializer escapes each value.
            string body = "{\"status\":" + status
                + ",\"app_field\":" + System.Text.Json.JsonSerializer.Serialize(appFieldB64)
                + ",\"app_id\":" + System.Text.Json.JsonSerializer.Serialize(appId)
                + ",\"app_detail\":" + System.Text.Json.JsonSerializer.Serialize(appDetail)
                + "}";

            System.Threading.Tasks.Task.Run(() =>
            {
                try
                {
                    // [Nextendo] Une seule decision, dans NextendoEndpoint : elle choisit qui recoit le
                // jeton du compte pose juste en dessous.
                string baseUrl = NextendoEndpoint.BaseUrl();

                    using HttpRequestMessage req = new(HttpMethod.Post, baseUrl.TrimEnd('/') + "/api/presence")
                    {
                        Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json"),
                    };
                    req.Headers.Add("Authorization", "Bearer " + token);
                    using HttpResponseMessage resp = _http.SendAsync(req).GetAwaiter().GetResult();
                }
                catch
                {
                    // best-effort presence; ignore failures
                }
                finally
                {
                    System.Threading.Interlocked.Exchange(ref _publishing, 0);
                }
            });
        }
    }
}
