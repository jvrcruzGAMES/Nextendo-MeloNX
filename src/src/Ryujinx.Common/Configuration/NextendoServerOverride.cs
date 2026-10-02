using Ryujinx.Common.Logging;
using System;
using System.IO;
using System.Net;
using System.Text.Json;

namespace Ryujinx.Common.Configuration
{
    /// <summary>
    /// [Nextendo] Serveur personnalisé : faire tourner l'émulateur sur le serveur de
    /// quelqu'un d'autre, entièrement en dehors de Nextendo Network.
    ///
    /// ⚠️ C'EST UN INTERRUPTEUR GÉNÉRAL, PAS UNE SIMPLE REDIRECTION. Quand il est actif,
    /// l'émulateur ne parle plus du tout à Nextendo : pas de compte, pas de jeton, pas
    /// d'amis, pas de sauvegarde en ligne, pas de présence, pas de contrôle de version,
    /// pas de statut Discord Nextendo. C'est <see cref="HorsNextendo"/> qui le décide, et
    /// tout ce qui touche à nos services doit passer par lui.
    ///
    /// Pourquoi si radical : chaque requête vers notre API porte le jeton du compte, et ce
    /// jeton donne un accès complet au compte. Tant que le mode « serveur personnalisé »
    /// laissait le compte actif, il fallait verrouiller l'adresse de l'API pour que
    /// « mets cette IP, les serveurs sont plus rapides » ne devienne pas une méthode de vol
    /// de comptes. En coupant le compte entièrement, le problème disparaît : il n'y a plus
    /// de jeton à détourner. Le mode est plus simple ET plus sûr qu'une redirection
    /// partielle, et il correspond à ce qu'attend vraiment quelqu'un qui joue chez lui.
    ///
    /// DEUX adresses, pas une. Pia exige que les deux répondeurs du contrôle NAT soient
    /// à des adresses PUBLIQUES DISTINCTES : face à une seule, il les déduplique,
    /// n'envoie jamais la seconde sonde, et le contrôle n'aboutit jamais (2618-201).
    /// Le second champ vide ne peut donc plus retomber sur notre répondeur — ce serait
    /// « quelque chose qui vient de Nextendo » — il faut deux adresses de son côté.
    /// </summary>
    public static class NextendoServerOverride
    {
        private sealed class Reglages
        {
            public bool Enabled { get; set; }
            public string ServerIp { get; set; } = "";
            public string NatIp { get; set; } = "";
        }

        private static string FilePath => Path.Combine(AppDataManager.BaseDirPath, "nextendo_server_override.json");

        private static Reglages _cache;
        private static bool _charge;

        private static Reglages Courant()
        {
            if (_charge)
            {
                return _cache;
            }

            _charge = true;
            _cache = new Reglages();

            try
            {
                if (File.Exists(FilePath))
                {
                    _cache = JsonSerializer.Deserialize<Reglages>(File.ReadAllText(FilePath)) ?? new Reglages();
                }
            }
            catch (Exception ex)
            {
                // Un fichier illisible ne doit pas empêcher l'émulateur de démarrer :
                // on retombe sur les serveurs officiels, ce qui est l'état sûr.
                Logger.Warning?.Print(LogClass.Application, $"[Nextendo] override illisible: {ex.Message}");
            }

            return _cache;
        }

        /// <summary>La redirection est-elle active ET utilisable ?</summary>
        public static bool IsActive
        {
            get
            {
                Reglages r = Courant();

                return r.Enabled && Valide(r.ServerIp) is not null;
            }
        }

        /// <summary>L'adresse à substituer aux serveurs de jeu, ou null si inactive.</summary>
        public static IPAddress ServerAddress => IsActive ? Valide(Courant().ServerIp) : null;

        /// <summary>
        /// L'adresse du SECOND répondeur NAT. Null si non renseignée : l'appelant doit
        /// alors garder la sienne, et surtout PAS réutiliser ServerAddress — deux
        /// répondeurs à la même adresse font échouer le contrôle NAT en silence.
        /// </summary>
        public static IPAddress NatAddress => IsActive ? Valide(Courant().NatIp) : null;

        public static bool Enabled => Courant().Enabled;
        public static string ServerIpText => Courant().ServerIp ?? "";
        public static string NatIpText => Courant().NatIp ?? "";

        /// <summary>
        /// ⚠️ LA question à poser avant tout ce qui touche à Nextendo. Vraie dès que le mode
        /// « serveur personnalisé » est coché, MÊME si l'adresse saisie est invalide.
        ///
        /// C'est volontaire, et c'est le point délicat : <see cref="IsActive"/> exige une
        /// adresse utilisable, parce qu'on ne peut pas rediriger vers rien. Ici c'est
        /// l'inverse — quelqu'un qui a coché la case a dit qu'il ne veut pas de nos services,
        /// et une faute de frappe dans son adresse ne doit surtout pas le reconnecter en
        /// silence à notre compte et à nos serveurs. Le mode dégradé, c'est « hors ligne »,
        /// pas « retour chez Nextendo ».
        /// </summary>
        public static bool HorsNextendo => Courant().Enabled;

        /// <summary>Enregistre les réglages et les applique au prochain démarrage.</summary>
        public static void Save(bool enabled, string serverIp, string natIp)
        {
            Reglages r = new()
            {
                Enabled = enabled,
                ServerIp = (serverIp ?? "").Trim(),
                NatIp = (natIp ?? "").Trim(),
            };

            _cache = r;
            _charge = true;

            try
            {
                File.WriteAllText(FilePath, JsonSerializer.Serialize(r, new JsonSerializerOptions { WriteIndented = true }));

                Logger.Info?.Print(LogClass.Application,
                    enabled
                        ? $"[Nextendo] redirection reseau ACTIVE : jeu -> {r.ServerIp}, NAT -> {(string.IsNullOrEmpty(r.NatIp) ? "(inchange)" : r.NatIp)}"
                        : "[Nextendo] redirection reseau desactivee, retour aux serveurs officiels");
            }
            catch (Exception ex)
            {
                Logger.Error?.Print(LogClass.Application, $"[Nextendo] override non enregistre: {ex.Message}");
            }
        }

        /// <summary>
        /// Une adresse IP littérale, ou null. On refuse volontairement les noms d'hôte :
        /// le résolveur qui consomme cette valeur est précisément celui qui intercepte
        /// la résolution DNS, et lui donner un nom à résoudre serait circulaire.
        /// </summary>
        private static IPAddress Valide(string brut)
        {
            string s = (brut ?? "").Trim().Trim('"', '\'', '“', '”', '‘', '’');

            if (s.Length == 0)
            {
                return null;
            }

            return IPAddress.TryParse(s, out IPAddress ip) ? ip : null;
        }
    }
}
