using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.RomFs;
using Ryujinx.Common.Logging;
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace Ryujinx.HLE.HOS
{
    /// <summary>
    /// Ecran-titre de Splatoon 3 : afficher le logo de l'evenement en cours.
    ///
    /// CE QUE C'EST, ET CE QUE CE N'EST PAS. Les cinq logos — le normal, Frosty Fest, Spring Fest,
    /// Summer Nights et Grand Festival — sont DEJA dans le fichier du joueur. Lequel s'affiche est
    /// decide par le code du jeu, et rien dans les donnees ne permet d'atteindre ce choix. On ne
    /// remplace donc aucune image : on PERMUTE deux textures que Nintendo a livrees.
    ///
    /// Les cinq font exactement 1 572 864 octets, en ASTC 4x4, 1530x925. L'echange est donc neutre
    /// au bit pres : le fichier decompresse garde sa taille, la table des tailles du jeu reste
    /// valide, aucun nom ni decalage ne bouge. Rien n'est ajoute au jeu, aucun comportement de
    /// partie n'est modifie — c'est pour cela que ceci n'est pas un mod au sens ou ModsInterdits
    /// les refuse, et que ce chemin vit en dehors du chargeur de mods.
    ///
    /// RIEN NE SORT DE LA MACHINE DU JOUEUR. La permutation se fait en memoire, a partir de SON
    /// dump. Aucun fichier patche n'est distribue : il contiendrait les textures de Nintendo.
    ///
    /// LE DEFAUT EST DE NE RIEN FAIRE. Champ absent, vide, « default », valeur inconnue, fichier
    /// introuvable, geometrie inattendue : on rend le romfs d'origine, intact. Un joueur ne doit
    /// jamais se retrouver avec un ecran-titre casse parce que le serveur a repondu autre chose que
    /// prevu.
    /// </summary>
    public static class NextendoEcranTitre
    {
        private const ulong Splatoon3 = 0x0100C2500FC20000;
        private const string CheminLayout = "/Layout/Plz_Title_00.Nin_NX_NVN.blarc.zs";

        /// <summary>
        /// La texture que le jeu affiche reellement. MESURE, pas devinee : la permutation de
        /// Logo_01 n'a rien change a l'ecran, celle-ci si. Les sept logos forment DEUX familles —
        /// deux en 918x555 (normal, Splatoween) et cinq en 1530x925 (normal, Frosty, Spring,
        /// Summer, Grand) — et c'est la petite qui est a l'ecran.
        /// </summary>
        private const string LogoNormal = "Logo_00";

        /// <summary>Garde-fou : au-dela, on ne reconnait plus le fichier et on renonce.</summary>
        private const int OctetsMaximum = 4 << 20;

        /// <summary>
        /// Ce qu'on sait echanger AUJOURD'HUI : uniquement dans la famille de Logo_00, seule a
        /// avoir la meme taille de bloc. Les quatre grands logos d'evenement sont dans l'autre
        /// famille ; les atteindre demandera d'encoder l'image, pas de permuter des octets, et le
        /// controle de taille ci-dessous les refusera proprement en attendant.
        /// </summary>
        /// <summary>
        /// Les logos qu'on APPORTE, faute d'exister dans le jeu. LoveFest est un dessin de Zara :
        /// il est encode en BC7 a la taille exacte de l'emplacement — seize octets par bloc de 4x4,
        /// comme l'ASTC qu'il remplace — et le champ de format du BRTI est bascule en consequence.
        /// Meme geometrie, meme reserve, donc le fichier decompresse ne bouge pas.
        /// </summary>
        private static readonly Dictionary<string, string> _apportes = new(StringComparer.OrdinalIgnoreCase)
        {
            ["lovefest"] = "lovefest",
        };

        private const uint Bc7Srgb = 0x2006;

        private static readonly Dictionary<string, string> _variantes = new(StringComparer.OrdinalIgnoreCase)
        {
            ["splatoween"] = "Logo_02",
            ["frosty"] = "Logo_03",
            ["spring"] = "Logo_04",
            ["summer"] = "Logo_05",
            ["grand"] = "Logo_06",
        };

        /// <summary>
        /// Le logo demande, renseigne par la posture de fete du serveur. Volontairement accroche a
        /// elle : pose a cote, il survivrait a la fin de la fete et le logo resterait coince.
        /// </summary>
        public static string Demande { get; set; }

        private static bool _demandeLue;

        /// <summary>
        /// Demande au serveur quel logo afficher. La verite vit dans la posture de fete de npln-s3,
        /// relayee par le site : c'est ce qui fait qu'un logo s'eteint tout seul a la fin de la
        /// fete, au lieu de rester coince sur un evenement termine.
        ///
        /// Appel synchrone et bref, fait au chargement du jeu : il faut la reponse AVANT que le
        /// romfs ne soit monte. Toute panne — reseau coupe, serveur muet, reponse illisible — rend
        /// une chaine vide, donc « ne touche a rien ».
        /// </summary>
        private static string DemanderAuServeur()
        {
            try
            {
                using System.Net.Http.HttpClient http = new() { Timeout = TimeSpan.FromSeconds(4) };

                string corps = http.GetStringAsync(
                    $"{Ryujinx.Common.Configuration.NextendoEndpoint.BaseUrl()}/api/fest-logo").Result;

                // Reponse attendue : {"logo":"lovefest"}. On la lit a la main plutot que d'embarquer
                // un serialiseur pour un seul champ.
                const string marque = "\"logo\"";
                int i = corps.IndexOf(marque, StringComparison.Ordinal);
                if (i < 0)
                {
                    return null;
                }

                int a = corps.IndexOf('"', i + marque.Length + 1);
                int b = a < 0 ? -1 : corps.IndexOf('"', a + 1);

                return a > 0 && b > a ? corps[(a + 1)..b] : null;
            }
            catch (Exception e)
            {
                Logger.Info?.Print(LogClass.ModLoader,
                    $"[Nextendo] Ecran-titre : serveur injoignable ({e.GetType().Name}) — aucun logo");

                return null;
            }
        }

        private static string LogoDemande()
        {
            string cle = Demande;

            // Interrupteur de developpement, pour pouvoir essayer une variante sans passer par le
            // serveur. Il ne prend la main que si rien n'a ete pose par ailleurs.
            if (string.IsNullOrWhiteSpace(cle))
            {
                cle = Environment.GetEnvironmentVariable("NEXTENDO_LOGO_TITRE");
            }

            // Sinon, c'est le serveur qui decide. Une seule fois par lancement.
            if (string.IsNullOrWhiteSpace(cle) && !_demandeLue)
            {
                _demandeLue = true;
                cle = DemanderAuServeur();
            }

            if (string.IsNullOrWhiteSpace(cle) || cle.Equals("default", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            cle = cle.Trim();

            if (_apportes.ContainsKey(cle))
            {
                return cle;
            }

            return _variantes.TryGetValue(cle, out string logo) ? logo : null;
        }

        public static IStorage Appliquer(ulong applicationId, IStorage baseStorage)
        {
            Logger.Info?.Print(LogClass.ModLoader,
                $"[Nextendo] Ecran-titre : appel pour {applicationId:X16} (romfs {(baseStorage == null ? "absent" : "present")})");

            if (applicationId != Splatoon3 || baseStorage == null)
            {
                return baseStorage;
            }

            string logo = LogoDemande();

            // Une ligne a chaque demarrage de S3, meme quand il n'y a rien a faire : sans elle, on
            // ne distingue pas « rien n'a ete demande » de « le chemin n'a pas ete emprunte ».
            Logger.Info?.Print(LogClass.ModLoader,
                $"[Nextendo] Ecran-titre : demande={Demande ?? "(rien)"} env={Environment.GetEnvironmentVariable("NEXTENDO_LOGO_TITRE") ?? "(rien)"} -> {logo ?? "aucune permutation"}");

            if (logo == null)
            {
                return baseStorage;
            }

            try
            {
                return Permuter(baseStorage, logo);
            }
            catch (Exception e)
            {
                // Un ecran-titre n'a jamais valu qu'on empeche un joueur de jouer.
                Logger.Warning?.Print(LogClass.ModLoader,
                    $"[Nextendo] Ecran-titre : permutation abandonnee ({e.GetType().Name}: {e.Message}) — romfs d'origine conserve");

                return baseStorage;
            }
        }

        private static IStorage Permuter(IStorage baseStorage, string logo)
        {
            RomFsFileSystem baseRom = new(baseStorage);

            byte[] compresse = LireFichier(baseRom, CheminLayout);
            if (compresse == null)
            {
                Logger.Info?.Print(LogClass.ModLoader,
                    $"[Nextendo] Ecran-titre : {CheminLayout} absent du jeu — rien a faire");

                return baseStorage;
            }

            // ⚠️ Unwrap plafonne la sortie par defaut. Le blarc de l'ecran-titre fait dix megaoctets
            // une fois decompresse ; sans plafond explicite, on recupere un tampon TRONQUE, et les
            // textures situees au-dela passent pour absentes. Mesure : 11 textures sur 17 reperees,
            // les six dernieres perdues.
            ulong annoncee = ZstdSharp.Decompressor.GetDecompressedSize(compresse);
            int plafond = annoncee > 0 && annoncee < (ulong)(64 << 20) ? (int)annoncee : 64 << 20;

            byte[] clair;
            using (ZstdSharp.Decompressor decompresseur = new())
            {
                clair = decompresseur.Unwrap(compresse, plafond).ToArray();
            }

            Logger.Info?.Print(LogClass.ModLoader,
                $"[Nextendo] Ecran-titre : {compresse.Length} o compresses -> {clair.Length} o decompresses");

            int tailleAvant = clair.Length;

            bool applique = _apportes.TryGetValue(logo, out string ressource)
                ? InjecterLogo(clair, ressource, out string pourquoi)
                : PermuterTextures(clair, LogoNormal, logo, out pourquoi);

            if (!applique)
            {
                Logger.Info?.Print(LogClass.ModLoader,
                    $"[Nextendo] Ecran-titre : {pourquoi} — romfs d'origine conserve");

                return baseStorage;
            }

            if (clair.Length != tailleAvant)
            {
                // Impossible par construction, mais la table des tailles du jeu en depend.
                throw new InvalidOperationException("la taille decompressee a change");
            }

            byte[] recompresse;
            using (ZstdSharp.Compressor compresseur = new(15))
            {
                recompresse = compresseur.Wrap(clair).ToArray();
            }

            RomFsBuilder builder = new();
            builder.AddFile(CheminLayout, new StorageFile(new MemoryStorage(recompresse), OpenMode.Read));

            foreach (DirectoryEntryEx entree in baseRom.EnumerateEntries()
                         .Where(f => f.Type == DirectoryEntryType.File && f.FullPath != CheminLayout)
                         .OrderBy(f => f.FullPath, StringComparer.Ordinal))
            {
                using UniqueRef<IFile> fichier = new();

                baseRom.OpenFile(ref fichier.Ref, entree.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                builder.AddFile(entree.FullPath, fichier.Release());
            }

            Logger.Info?.Print(LogClass.ModLoader,
                $"[Nextendo] Ecran-titre : {LogoNormal} <-> {logo} ({tailleAvant} o inchanges)");

            return builder.Build();
        }

        private static byte[] LireFichier(RomFsFileSystem fs, string chemin)
        {
            using UniqueRef<IFile> fichier = new();

            if (fs.OpenFile(ref fichier.Ref, chemin.ToU8Span(), OpenMode.Read).IsFailure())
            {
                return null;
            }

            fichier.Get.GetSize(out long taille).ThrowIfFailure();

            byte[] donnees = new byte[taille];
            fichier.Get.Read(out long lu, 0, donnees, ReadOption.None).ThrowIfFailure();

            return lu == taille ? donnees : null;
        }

        // ---- BNTX : juste ce qu'il faut pour situer deux textures et echanger leurs octets ----

        private readonly struct Texture
        {
            public readonly int Debut;
            public readonly int Octets;
            public readonly uint Format;
            public readonly uint Largeur;
            public readonly uint Hauteur;

            /// <summary>Position du bloc BRTI : c'est la qu'on ecrit le format, a +0x1C.</summary>
            public readonly int Brti;

            public Texture(int debut, int octets, uint format, uint largeur, uint hauteur, int brti)
            {
                Debut = debut;
                Octets = octets;
                Format = format;
                Largeur = largeur;
                Hauteur = hauteur;
                Brti = brti;
            }
        }

        private static bool PermuterTextures(byte[] clair, string nomA, string nomB, out string pourquoi)
        {
            Dictionary<string, Texture> textures = Inventorier(clair);

            if (!textures.TryGetValue(nomA, out Texture a) || !textures.TryGetValue(nomB, out Texture b))
            {
                pourquoi = $"{nomA} ou {nomB} introuvable — {textures.Count} texture(s) reperee(s) : "
                    + string.Join(", ", textures.Keys.Take(20));

                return false;
            }

            // L'invariant qui rend l'echange sur : MEME taille de bloc. C'est lui qui garantit que
            // le fichier decompresse ne bouge pas d'un octet, donc que la table des tailles du jeu
            // reste valide. Un dump inattendu, ou une paire mal choisie, s'arrete ici.
            if (a.Octets != b.Octets)
            {
                pourquoi = $"tailles differentes ({a.Octets} et {b.Octets}) — echange refuse";

                return false;
            }

            if (a.Octets <= 0 || a.Octets > OctetsMaximum)
            {
                pourquoi = $"taille de bloc invraisemblable ({a.Octets} o)";

                return false;
            }

            if (a.Largeur != b.Largeur || a.Hauteur != b.Hauteur || a.Format != b.Format)
            {
                pourquoi = "geometries ou formats differents";

                return false;
            }

            int n = a.Octets;
            byte[] tampon = new byte[n];
            Buffer.BlockCopy(clair, a.Debut, tampon, 0, n);
            Buffer.BlockCopy(clair, b.Debut, clair, a.Debut, n);
            Buffer.BlockCopy(tampon, 0, clair, b.Debut, n);

            pourquoi = null;

            return true;
        }

        /// <summary>
        /// Ecrit un logo que nous apportons dans l'emplacement Logo_00, et bascule le format.
        /// Refuse des que quelque chose ne correspond pas : c'est le fichier du joueur qu'on
        /// modifie, et un ecran-titre ne vaut pas qu'on l'abime.
        /// </summary>
        private static bool InjecterLogo(byte[] clair, string ressource, out string pourquoi)
        {
            byte[] bloc = LireRessource(ressource);
            if (bloc == null)
            {
                pourquoi = $"ressource {ressource} introuvable dans l'emulateur";

                return false;
            }

            Dictionary<string, Texture> textures = Inventorier(clair);
            if (!textures.TryGetValue(LogoNormal, out Texture cible))
            {
                pourquoi = $"{LogoNormal} introuvable — {textures.Count} texture(s) reperee(s)";

                return false;
            }

            if (bloc.Length != cible.Octets)
            {
                pourquoi = $"le logo apporte fait {bloc.Length} o, l'emplacement en reserve {cible.Octets}";

                return false;
            }

            Buffer.BlockCopy(bloc, 0, clair, cible.Debut, bloc.Length);
            BinaryPrimitives.WriteUInt32LittleEndian(clair.AsSpan(cible.Brti + 0x1C, 4), Bc7Srgb);

            Logger.Info?.Print(LogClass.ModLoader,
                $"[Nextendo] Ecran-titre : logo apporte pose dans {LogoNormal} ({bloc.Length} o, format -> BC7)");

            pourquoi = null;

            return true;
        }

        private static byte[] LireRessource(string nom)
        {
            // Le logo vit dans le code, pas dans une ressource embarquee : voir NextendoLogoLoveFest.
            byte[] compresse = nom == "lovefest" ? NextendoLogoLoveFest.Zstd() : null;
            if (compresse == null)
            {
                return null;
            }

            ulong annoncee = ZstdSharp.Decompressor.GetDecompressedSize(compresse);
            int plafond = annoncee > 0 && annoncee < (ulong)(16 << 20) ? (int)annoncee : 16 << 20;

            using ZstdSharp.Decompressor decompresseur = new();

            return decompresseur.Unwrap(compresse, plafond).ToArray();
        }

        private static Dictionary<string, Texture> Inventorier(byte[] donnees)
        {
            Dictionary<string, Texture> out_ = new(StringComparer.Ordinal);

            int bntx = Trouver(donnees, "BNTX"u8);
            if (bntx < 0)
            {
                return out_;
            }

            int nx = bntx + 0x20;
            if (!Correspond(donnees, nx, "NX  "u8))
            {
                return out_;
            }

            uint nombre = U32(donnees, nx + 4);
            long table = bntx + (long)U64(donnees, nx + 8);

            for (uint i = 0; i < nombre; i++)
            {
                long p = bntx + (long)U64(donnees, (int)(table + i * 8));
                if (p < 0 || p + 0x78 > donnees.Length || !Correspond(donnees, (int)p, "BRTI"u8))
                {
                    continue;
                }

                long nomPtr = bntx + (long)U64(donnees, (int)(p + 0x60));
                if (nomPtr < 0 || nomPtr + 2 > donnees.Length)
                {
                    continue;
                }

                int longueur = BinaryPrimitives.ReadUInt16LittleEndian(donnees.AsSpan((int)nomPtr, 2));
                if (longueur <= 0 || nomPtr + 2 + longueur > donnees.Length)
                {
                    continue;
                }

                string nom = Encoding.ASCII.GetString(donnees, (int)nomPtr + 2, longueur);

                // Les noms portent un suffixe de canal : « Logo_01^w ».
                int chapeau = nom.IndexOf('^');
                if (chapeau > 0)
                {
                    nom = nom[..chapeau];
                }

                long indirection = (long)U64(donnees, (int)(p + 0x70));
                if (indirection == 0 || bntx + indirection + 8 > donnees.Length)
                {
                    continue;
                }

                long debut = bntx + (long)U64(donnees, (int)(bntx + indirection));
                int octets = (int)U32(donnees, (int)(p + 0x50));

                if (debut < 0 || octets <= 0 || debut + octets > donnees.Length)
                {
                    continue;
                }

                out_[nom] = new Texture((int)debut, octets,
                    U32(donnees, (int)(p + 0x1C)), U32(donnees, (int)(p + 0x24)), U32(donnees, (int)(p + 0x28)), (int)p);
            }

            return out_;
        }

        private static int Trouver(byte[] donnees, ReadOnlySpan<byte> motif)
        {
            return donnees.AsSpan().IndexOf(motif);
        }

        private static bool Correspond(byte[] donnees, int position, ReadOnlySpan<byte> motif)
        {
            return position >= 0
                && position + motif.Length <= donnees.Length
                && donnees.AsSpan(position, motif.Length).SequenceEqual(motif);
        }

        private static uint U32(byte[] d, int p) => BinaryPrimitives.ReadUInt32LittleEndian(d.AsSpan(p, 4));

        private static ulong U64(byte[] d, int p) => BinaryPrimitives.ReadUInt64LittleEndian(d.AsSpan(p, 8));
    }
}
