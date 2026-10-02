using Avalonia.Threading;
using Ryujinx.Ava.Systems.AppLibrary;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Logging;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace Ryujinx.Ava.Common
{
    /// <summary>
    /// [Nextendo] Pushes the local play history (every game ever played, with its play time and last
    /// played date) to the account. Used to be done ONLY when the Settings > Nextendo Network tab was
    /// opened, so a session's time never reached the account unless the user happened to visit that tab.
    /// Now it is also pushed on every way a game can end — the Stop action, closing the window (Alt+F4),
    /// and a caught crash — mirroring how the cloud-save sync is wired into those same paths.
    /// </summary>
    public static class NextendoHistorySync
    {

        // [Nextendo] --- Poussee PERIODIQUE, et icones envoyees une seule fois -------------------
        //
        // POURQUOI. L'historique ne partait qu'a la fin d'un jeu, a la fermeture de la fenetre ou a
        // une annulation de chargement. Un emulateur tue, plante, ou simplement laisse ouvert
        // pendant des heures n'envoyait donc RIEN. Mesure du 2026-08-23 : le compte 1800000006 a
        // joue plusieurs sessions et son historique cote serveur datait encore du 20 aout.
        //
        // ET POURQUOI CA NE COUTE PAS CHER. Une poussee complete pese lourd, mais uniquement a
        // cause des icones : sur 40 historiques pris au hasard, 14,6 Mo de donnees dont 14,6 Mo
        // d'icones — CENT pour cent. Or le serveur conserve l'icone qu'il possede deja quand celle
        // qu'on lui envoie est vide (mergeHistory : « if e.Icon != "" »). On peut donc pousser les
        // temps de jeu sans les images, et ne joindre une icone que pour un titre dont le serveur
        // n'en a pas encore.
        //
        // La reponse du serveur porte l'historique fusionne, icones comprises : elle nous dit donc
        // exactement quels titres sont deja illustres la-bas. On s'en sert pour ne jamais renvoyer
        // deux fois la meme image.

        /// <summary>Intervalle entre deux poussees pendant qu'on joue.</summary>
        private static readonly TimeSpan IntervalleDePoussee = TimeSpan.FromMinutes(5);

        /// <summary>Titres dont le serveur possede deja l'icone : on ne la lui renvoie plus.</summary>
        private static readonly HashSet<string> _iconesChezLeServeur = new(StringComparer.OrdinalIgnoreCase);

        /// <summary>Dernier etat pousse par titre, pour n'envoyer que ce qui a bouge.</summary>
        private static readonly Dictionary<string, string> _dernierEtatPousse = new(StringComparer.OrdinalIgnoreCase);

        private static readonly object _verrou = new();
        private static System.Threading.Timer _horloge;

        /// <summary>
        /// Demarre la poussee periodique. Appelable plusieurs fois sans risque : la deuxieme ne fait
        /// rien. Ne pousse jamais si le compte n'est pas lie — PushAsync s'en charge.
        /// </summary>
        public static void DemarrerPousseePeriodique()
        {
            lock (_verrou)
            {
                if (_horloge != null)
                {
                    return;
                }

                _horloge = new System.Threading.Timer(
                    _ => _ = PushAsync("periodique"),
                    null,
                    IntervalleDePoussee,
                    IntervalleDePoussee);
            }

            Logger.Info?.Print(LogClass.Application,
                $"[Nextendo] history: poussee periodique toutes les {IntervalleDePoussee.TotalMinutes:0} min");
        }

        /// <summary>Arrete la poussee periodique (fermeture de l'application).</summary>
        public static void ArreterPousseePeriodique()
        {
            lock (_verrou)
            {
                _horloge?.Dispose();
                _horloge = null;
            }
        }

        /// <summary>
        /// Reduit la liste a ce qui merite d'etre envoye : les titres dont le temps de jeu ou la
        /// date ont change depuis la derniere poussee reussie. L'icone n'est jointe que si le
        /// serveur ne l'a pas deja.
        /// </summary>
        private static List<NextendoApi.HistoryItem> ADestinationDuServeur(List<NextendoApi.HistoryItem> local)
        {
            List<NextendoApi.HistoryItem> sortie = [];

            lock (_verrou)
            {
                foreach (NextendoApi.HistoryItem h in local)
                {
                    if (string.IsNullOrEmpty(h.TitleId))
                    {
                        continue;
                    }

                    string etat = h.Seconds + "|" + h.LastPlayed;
                    bool aBouge = !_dernierEtatPousse.TryGetValue(h.TitleId, out string vu) || vu != etat;
                    bool doitEnvoyerIcone = !string.IsNullOrEmpty(h.IconBase64)
                                            && !_iconesChezLeServeur.Contains(h.TitleId);

                    if (!aBouge && !doitEnvoyerIcone)
                    {
                        continue;
                    }

                    sortie.Add(new NextendoApi.HistoryItem
                    {
                        TitleId = h.TitleId,
                        Name = h.Name,
                        IconBase64 = doitEnvoyerIcone ? h.IconBase64 : "",
                        Seconds = h.Seconds,
                        LastPlayed = h.LastPlayed,
                    });
                }
            }

            return sortie;
        }

        /// <summary>
        /// Enregistre ce que le serveur nous a confirme : les etats pousses, et les titres dont il
        /// detient desormais l'icone.
        /// </summary>
        private static void NoterCeQueLeServeurSait(List<NextendoApi.HistoryItem> envoye, List<NextendoApi.HistoryItem> reponse)
        {
            lock (_verrou)
            {
                foreach (NextendoApi.HistoryItem h in envoye)
                {
                    _dernierEtatPousse[h.TitleId] = h.Seconds + "|" + h.LastPlayed;
                }

                foreach (NextendoApi.HistoryItem h in reponse)
                {
                    if (!string.IsNullOrEmpty(h.TitleId) && !string.IsNullOrEmpty(h.IconBase64))
                    {
                        _iconesChezLeServeur.Add(h.TitleId);
                    }
                }
            }
        }

        /// <summary>
        /// Every game ever played, with the freshest play time available. The play time of the session
        /// that just ended is written to the title's metadata file by <c>AppHost.Dispose</c> right before
        /// the close hooks run, so we fold that file in (the in-memory <see cref="ApplicationData"/> may
        /// not have been refreshed yet). Reads are done only for titles that already have a metadata file,
        /// so a never-played title never gets a default file created for it.
        /// </summary>
        public static List<NextendoApi.HistoryItem> CollectLocalHistory()
        {
            List<NextendoApi.HistoryItem> list = [];

            var apps = RyujinxApp.MainWindow?.ViewModel?.Applications;
            if (apps == null)
            {
                return list;
            }

            foreach (ApplicationData app in apps.ToArray())
            {
                TimeSpan time = app.TimePlayed;
                DateTime? last = app.LastPlayed;

                if (MetadataExists(app.IdString))
                {
                    try
                    {
                        Gommon.Optional<ApplicationMetadata> meta = ApplicationLibrary.LoadAndSaveMetaData(app.IdString);
                        if (meta.HasValue)
                        {
                            if (meta.Value.TimePlayed > time)
                            {
                                time = meta.Value.TimePlayed;
                            }

                            if (meta.Value.LastPlayed.HasValue && (last == null || meta.Value.LastPlayed > last))
                            {
                                last = meta.Value.LastPlayed;
                            }
                        }
                    }
                    catch
                    {
                        // Fall back to the in-memory values.
                    }
                }

                if (last == null && time.TotalSeconds < 1)
                {
                    continue; // never played
                }

                list.Add(new NextendoApi.HistoryItem
                {
                    TitleId = app.IdString,
                    Name = app.Name,
                    IconBase64 = app.Icon is { Length: > 0 } ? Convert.ToBase64String(app.Icon) : "",
                    Seconds = (long)time.TotalSeconds,
                    LastPlayed = last?.ToUniversalTime().ToString("o") ?? "",
                });
            }

            return list;
        }

        /// <summary>
        /// Push the history to the account. No-op (with a log line) when the account is not linked or
        /// nothing has been played. Never throws — a failed push must never take down a game-close path.
        /// The collection is read on the UI thread (close hooks can fire from the emulation thread).
        /// </summary>
        public static async Task PushAsync(string reason)
        {
            if (!NextendoAccount.IsLinked)
            {
                Logger.Info?.Print(LogClass.Application, $"[Nextendo] history push skipped ({reason}): account not linked");
                return;
            }

            try
            {
                List<NextendoApi.HistoryItem> local = Dispatcher.UIThread.CheckAccess()
                    ? CollectLocalHistory()
                    : await Dispatcher.UIThread.InvokeAsync(CollectLocalHistory);

                if (local.Count == 0)
                {
                    Logger.Info?.Print(LogClass.Application, $"[Nextendo] history push skipped ({reason}): nothing played");
                    return;
                }

                // N'envoyer que ce qui a bouge, et l'icone une seule fois. Voir le bloc en tete
                // de classe : sans ce filtre, une poussee toutes les cinq minutes reexpedierait des
                // megaoctets d'images que le serveur possede deja.
                List<NextendoApi.HistoryItem> aEnvoyer = ADestinationDuServeur(local);
                if (aEnvoyer.Count == 0)
                {
                    Logger.Debug?.Print(LogClass.Application, $"[Nextendo] history push skipped ({reason}): rien de nouveau");
                    return;
                }

                List<NextendoApi.HistoryItem> fusionne = await NextendoApi.SyncHistoryAsync(aEnvoyer);
                NoterCeQueLeServeurSait(aEnvoyer, fusionne);

                int avecIcone = aEnvoyer.Count(x => !string.IsNullOrEmpty(x.IconBase64));
                Logger.Info?.Print(LogClass.Application,
                    $"[Nextendo] history pushed ({reason}): {aEnvoyer.Count} title(s), {avecIcone} icon(s)");
            }
            catch (Exception ex)
            {
                Logger.Warning?.Print(LogClass.Application, $"[Nextendo] history push failed ({reason}): {ex.Message}");
            }
        }

        private static bool MetadataExists(string titleId)
        {
            if (string.IsNullOrEmpty(titleId))
            {
                return false;
            }

            try
            {
                return File.Exists(Path.Combine(AppDataManager.GamesDirPath, titleId, "gui", "metadata.json"));
            }
            catch
            {
                return false;
            }
        }
    }
}
