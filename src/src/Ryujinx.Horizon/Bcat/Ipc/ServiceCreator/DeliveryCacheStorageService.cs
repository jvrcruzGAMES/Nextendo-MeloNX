using LibHac.Bcat;
using LibHac.Common;
using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Bcat;
using Ryujinx.Horizon.Sdk.Sf;
using Ryujinx.Horizon.Sdk.Sf.Hipc;
using System;
using System.Linq;
using System.Threading;

namespace Ryujinx.Horizon.Bcat.Ipc
{
    partial class DeliveryCacheStorageService : IDeliveryCacheStorageService, IDisposable
    {
        private SharedRef<LibHac.Bcat.Impl.Ipc.IDeliveryCacheStorageService> _libHacService;
        private int _disposalState;
        private readonly string _seedRoot;

        public DeliveryCacheStorageService(ref SharedRef<LibHac.Bcat.Impl.Ipc.IDeliveryCacheStorageService> libHacService, string seedRoot = null)
        {
            _libHacService = SharedRef<LibHac.Bcat.Impl.Ipc.IDeliveryCacheStorageService>.CreateMove(ref libHacService);
            _seedRoot = seedRoot ?? BcatSeed.Root;
        }

        [CmifCommand(0)]
        public Result CreateFileService(out IDeliveryCacheFileService service)
        {
            using SharedRef<LibHac.Bcat.Impl.Ipc.IDeliveryCacheFileService> libHacService = new();

            LibHac.Result resultCode = _libHacService.Get.CreateFileService(ref libHacService.Ref);

            if (resultCode.IsSuccess())
            {
                service = new DeliveryCacheFileService(ref libHacService.Ref, _seedRoot);
            }
            else
            {
                service = null;
            }

            return resultCode.Horizon;
        }

        [CmifCommand(1)]
        public Result CreateDirectoryService(out IDeliveryCacheDirectoryService service)
        {
            using SharedRef<LibHac.Bcat.Impl.Ipc.IDeliveryCacheDirectoryService> libHacService = new();

            LibHac.Result resultCode = _libHacService.Get.CreateDirectoryService(ref libHacService.Ref);

            if (resultCode.IsSuccess())
            {
                service = new DeliveryCacheDirectoryService(ref libHacService.Ref, _seedRoot);
            }
            else
            {
                service = null;
            }

            return resultCode.Horizon;
        }

        [CmifCommand(10)]
        public Result EnumerateDeliveryCacheDirectory(out int count, [Buffer(HipcBufferFlags.Out | HipcBufferFlags.MapAlias)] Span<DirectoryName> directoryNames)
        {
            LibHac.Result res = _libHacService.Get.EnumerateDeliveryCacheDirectory(out count, directoryNames);

            // Le cache de livraison reel est toujours vide sous Ryujinx : rien ne le remplit. Un jeu
            // qui commence par DEMANDER LA LISTE des dossiers en trouve donc zero, et n'ouvre jamais
            // celui qu'il cherche — le repli de DeliveryCacheDirectoryService.Open, lui, ne se
            // declenche qu'a l'ouverture, donc trop tard. On complete ici avec ce que porte
            // reellement le dossier bcat-seed.
            if ((count == 0 || BcatSeed.PreferServerSeed(_seedRoot)) && System.IO.Directory.Exists(_seedRoot))
            {
                string[] dirs = System.IO.Directory.GetDirectories(_seedRoot)
                    .Where(dir => _seedRoot != BcatSeed.Root || !BcatSeed.IsTitleRoot(System.IO.Path.GetFileName(dir))).ToArray();
                int n = System.Math.Min(dirs.Length, directoryNames.Length);
                for (int i = 0; i < n; i++)
                {
                    DirectoryName dn = default;
                    BcatSeed.FillName(ref dn, new System.IO.DirectoryInfo(dirs[i]).Name);
                    directoryNames[i] = dn;
                }
                count = n;
                res = LibHac.Result.Success;
            }

            return res.Horizon;
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposalState, 1) == 0)
            {
                _libHacService.Destroy();
            }
        }
    }
}
