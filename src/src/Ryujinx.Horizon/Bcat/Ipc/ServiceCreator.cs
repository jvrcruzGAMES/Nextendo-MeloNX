using LibHac.Common;
using Ryujinx.Horizon.Bcat.Types;
using Ryujinx.Horizon.Sdk.Arp;
using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Bcat;
using Ryujinx.Horizon.Sdk.Sf;
using System;
using System.Threading;
using ApplicationId = Ryujinx.Horizon.Sdk.Ncm.ApplicationId;

namespace Ryujinx.Horizon.Bcat.Ipc
{
    partial class ServiceCreator : IServiceCreator, IDisposable
    {
        private readonly BcatServicePermissionLevel _permissionLevel;
        private readonly ArpApi _arp;

        // [Nextendo] Deuxieme poignee vers LibHac, ouverte en ADMIN et uniquement pour le repli
        // ci-dessous. La session du jeu reste sur bcat:u ; seule la creation du stockage passe par
        // un niveau superieur, et seulement apres qu'arp ait confirme que le titre demande est bien
        // celui du processus appelant.
        private SharedRef<LibHac.Bcat.Impl.Ipc.IServiceCreator> _libHacAdmin;
        private SharedRef<LibHac.Bcat.Impl.Ipc.IServiceCreator> _libHacService;

        private int _disposalState;

        public ServiceCreator(string serviceName, BcatServicePermissionLevel permissionLevel, ArpApi arp = null)
        {
            HorizonStatic.Options.BcatClient.Sm.GetService(ref _libHacService, serviceName).ThrowIfFailure();
            _permissionLevel = permissionLevel;
            _arp = arp;
        }

        [CmifCommand(0)]
        public Result CreateBcatService(out IBcatService bcatService, [ClientProcessId] ulong pid)
        {
            // TODO: Call arp:r GetApplicationLaunchProperty with the pid to get the TitleId.
            //       Add an instance of nn::bcat::detail::service::core::PassphraseManager.
            //       Add an instance of nn::bcat::detail::service::ServiceMemoryManager.
            //       Add an instance of nn::bcat::detail::service::core::TaskManager who loads "bcat-sys:/" system save data and opens "dc/task.bin". 
            //       If the file don't exist, create a new one (with a size of 0x800 bytes) and write 2 empty structs with a size of 0x400 bytes.

            bcatService = new BcatService(_permissionLevel);

            return Result.Success;
        }

        [CmifCommand(1)]
        public Result CreateDeliveryCacheStorageService(out IDeliveryCacheStorageService service, [ClientProcessId] ulong pid)
        {
            string seedRoot = BcatSeed.Root;
            if (_arp != null && _arp.GetApplicationInstanceId(out ulong seedInstance, pid).IsSuccess &&
                _arp.GetApplicationLaunchProperty(out ApplicationLaunchProperty seedProperty, seedInstance).IsSuccess)
            {
                seedRoot = BcatSeed.RootForTitle(seedProperty.ApplicationId.Id);
            }
            using SharedRef<LibHac.Bcat.Impl.Ipc.IDeliveryCacheStorageService> libHacService = new();

            LibHac.Result resultCode = _libHacService.Get.CreateDeliveryCacheStorageService(ref libHacService.Ref, pid);

            // [Nextendo] Cette commande resout le titre DEPUIS LE PID de l'appelant, ce que Ryujinx ne
            // faisait pas (le TODO ci-dessus le disait) : LibHac ne trouve pas l'application derriere
            // ce pid et refuse, 2002-6400 PermissionDenied. Splatoon 3 y bute au demarrage — il
            // reessaie toutes les demi-secondes et finit par afficher l'erreur.
            //
            // On resout donc le titre nous-memes via arp — pid -> instance -> ApplicationLaunchProperty
            // — puis on rappelle la variante PAR IDENTIFIANT, qui elle aboutit. C'est exactement ce que
            // fait le systeme, et Prepo procede deja ainsi dans cet emulateur.
            if (resultCode.IsFailure() && _arp != null)
            {
                Result arpRes = _arp.GetApplicationInstanceId(out ulong instanceId, pid);
                if (arpRes.IsSuccess)
                {
                    arpRes = _arp.GetApplicationLaunchProperty(out ApplicationLaunchProperty launchProperty, instanceId);
                    if (arpRes.IsSuccess)
                    {
                        // La variante PAR IDENTIFIANT est refusee depuis bcat:u (2122-0090,
                        // PermissionDenied) : ouvrir le stockage d'une application nommee demande un
                        // niveau superieur. On ouvre donc une poignee bcat:a pour ce seul appel.
                        if (!_libHacAdmin.HasValue)
                        {
                            HorizonStatic.Options.BcatClient.Sm.GetService(ref _libHacAdmin, "bcat:a").ThrowIfFailure();
                        }

                        resultCode = _libHacAdmin.Get.CreateDeliveryCacheStorageServiceWithApplicationId(
                            ref libHacService.Ref, new LibHac.ApplicationId(launchProperty.ApplicationId.Id));

                        Ryujinx.Common.Logging.Logger.Info?.Print(Ryujinx.Common.Logging.LogClass.ServiceBcat,
                            $"[Nextendo] pid {pid} -> titre {launchProperty.ApplicationId.Id:X16}, repli admin -> 0x{resultCode.Value:X}");
                    }
                }
            }

            if (resultCode.IsSuccess())
            {
                service = new DeliveryCacheStorageService(ref libHacService.Ref, seedRoot);
            }
            else
            {
                service = null;
            }

            return resultCode.Horizon;
        }

        [CmifCommand(2)]
        public Result CreateDeliveryCacheStorageServiceWithApplicationId(out IDeliveryCacheStorageService service, ApplicationId applicationId)
        {
            using SharedRef<LibHac.Bcat.Impl.Ipc.IDeliveryCacheStorageService> libHacService = new();

            LibHac.Result resultCode = _libHacService.Get.CreateDeliveryCacheStorageServiceWithApplicationId(ref libHacService.Ref, new LibHac.ApplicationId(applicationId.Id));

            // [Nextendo] Splatoon 3 recoit 2002-6400 (PermissionDenied) au demarrage, et l'origine
            // etait invisible : ce resultat traverse la couche telle quelle. On le journalise.
            Ryujinx.Common.Logging.Logger.Info?.Print(Ryujinx.Common.Logging.LogClass.ServiceBcat,
                $"[Nextendo] CreateDeliveryCacheStorageServiceWithApplicationId -> 0x{resultCode.Value:X} ({(resultCode.IsSuccess() ? "succes" : "ECHEC")})");

            if (resultCode.IsSuccess())
            {
                service = new DeliveryCacheStorageService(ref libHacService.Ref, BcatSeed.RootForTitle(applicationId.Id));
            }
            else
            {
                service = null;
            }

            return resultCode.Horizon;
        }

        [CmifCommand(3)]
        public Result CreateDeliveryCacheProgressService(out IDeliveryCacheProgressService service, [ClientProcessId] ulong pid)
        {
            // Legacy command (firmware 2.0.0-2.3.0): older titles such as Splatoon 2
            // v1.0.0 still call it. Mirrors BcatService.RequestSyncDeliveryCache, which
            // also hands back a fresh DeliveryCacheProgressService.
            service = new DeliveryCacheProgressService();

            return Result.Success;
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposalState, 1) == 0)
            {
                _libHacService.Destroy();
                _libHacAdmin.Destroy();
            }
        }
    }
}
