using Ryujinx.Common.Logging;
using System;

namespace Ryujinx.Common.Configuration
{
    /// <summary>
    /// [Nextendo] Quel circuit Mario Kart 8 Deluxe est en train de charger, SUR LE MOMENT.
    ///
    /// Pourquoi ce détour par le système de fichiers plutôt que par le rapport de jeu : le
    /// rapport qui nomme le circuit (salle « match ») n'est émis qu'à la FIN de la course.
    /// Le statut affichait donc la piste précédente pendant toute la course suivante — on
    /// pouvait terminer un circuit entier avant de le voir apparaître.
    ///
    /// Le jeu, lui, ouvre les fichiers du circuit AU CHARGEMENT, sous « Course/&lt;nom&gt;/… ».
    /// C'est le premier instant où l'information existe, et elle arrive avec plusieurs
    /// minutes d'avance sur le rapport.
    ///
    /// ⚠️ Le coût est payé sur CHAQUE accès fichier du jeu : la recherche est donc faite sur
    /// les octets bruts, sans allouer, et court-circuitée tant que personne n'écoute.
    /// </summary>
    public static class NextendoCourseWatcher
    {
        /// <summary>Le dernier circuit vu, sous son nom de dossier interne. Vide si aucun.</summary>
        public static string Courant { get; private set; } = "";

        /// <summary>Levé quand le circuit change réellement.</summary>
        public static event Action Change;

        /// <summary>
        /// Tant que c'est faux, <see cref="Observe"/> rend la main immédiatement. On n'écoute
        /// que pendant Mario Kart : les autres jeux ouvrent aussi des fichiers, et rien ne
        /// justifie de les scruter.
        /// </summary>
        public static bool Actif { get; private set; }

        public static void Demarrer()
        {
            Actif = true;
        }

        public static void Arreter()
        {
            Actif = false;

            if (Courant.Length > 0)
            {
                Courant = "";
                Prevenir();
            }
        }

        // « /Course/ » en ASCII. Le motif porte les deux barres : sans la première, il
        // attraperait aussi des noms de FICHIERS comme « Course.bars », et sans la seconde
        // il faudrait deviner où s'arrête le préfixe.
        private static ReadOnlySpan<byte> Motif => "/Course/"u8;

        /// <summary>
        /// Examine un chemin ouvert par le jeu. Reçoit les octets bruts tels qu'ils arrivent
        /// de la mémoire invitée : pas de chaîne construite, pas de copie.
        /// </summary>
        public static void Observe(ReadOnlySpan<byte> chemin)
        {
            if (!Actif || chemin.Length < 12)
            {
                return;
            }

            int i = chemin.IndexOf(Motif);
            if (i < 0)
            {
                return;
            }

            ReadOnlySpan<byte> reste = chemin[(i + Motif.Length)..];

            // Le nom du circuit court jusqu'à la barre suivante. Pas de barre = ce n'était pas
            // un dossier de circuit mais un fichier posé à côté ; on ignore.
            int fin = reste.IndexOf((byte)'/');
            if (fin <= 0 || fin > 40)
            {
                return;
            }

            ReadOnlySpan<byte> nom = reste[..fin];

            // Comparaison avant allocation : pendant un chargement, le même circuit passe des
            // centaines de fois. Construire une chaîne à chaque fois serait absurde.
            if (MemeQueCourant(nom))
            {
                return;
            }

            string trouve = System.Text.Encoding.ASCII.GetString(nom);

            Courant = trouve;
            Logger.Debug?.Print(LogClass.Application, $"[Nextendo] circuit en chargement : {trouve}");
            Prevenir();
        }

        private static bool MemeQueCourant(ReadOnlySpan<byte> nom)
        {
            string c = Courant;

            if (c.Length != nom.Length)
            {
                return false;
            }

            for (int k = 0; k < nom.Length; k++)
            {
                if (c[k] != (char)nom[k])
                {
                    return false;
                }
            }

            return true;
        }

        private static void Prevenir()
        {
            try
            {
                Change?.Invoke();
            }
            catch (Exception ex)
            {
                // Un abonné qui explose ne doit pas casser un accès fichier du jeu.
                Logger.Debug?.Print(LogClass.Application, $"[Nextendo] course watcher: {ex.Message}");
            }
        }
    }
}
