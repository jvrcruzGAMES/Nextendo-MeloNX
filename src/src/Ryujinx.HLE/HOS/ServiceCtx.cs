using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Kernel.Process;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.Memory;
using System.IO;

namespace Ryujinx.HLE.HOS
{
    class ServiceCtx
    {
        public Switch Device { get; }
        public KProcess Process { get; }
        public IVirtualMemoryManager Memory { get; }
        public KThread Thread { get; }
        public IpcMessage Request { get; }
        public IpcMessage Response { get; }
        public BinaryReader RequestData { get; }
        public BinaryWriter ResponseData { get; }
        public ulong ClientProcessId => Request.HandleDesc is { HasPId: true } ? Request.HandleDesc.PId : Process.Pid;

        // [Nextendo] deferred Bsd Poll (single-thread eventfd deadlock fix)
        // Poll sets PollDeferRequested when it wants to defer the IPC reply instead of busy-looping
        // on the single Bsd server thread (which would deadlock the eventfd Write that must run on
        // the same thread). The ServerBase loop drives the deferral machinery via these fields.
        public bool PollDeferRequested;     // Poll: "I would block, please defer my reply"
        public bool PollForceNonBlocking;   // Loop: "this is a re-run, do ONE non-blocking check, never defer"
        public int PollResult;              // Poll: updateCount from the last non-blocking pass (>0 => an fd is ready)
        public long PollDeadlineMs;         // absolute deadline in ms (long.MaxValue for timeout == -1)

        // [Nextendo] Copie GEREE du tableau pollfd, prise au moment ou le sondage est differe. Lors d'une
        // re-verification, le gestionnaire relit les descripteurs ICI et non en memoire invitee : le tampon
        // de type 0x21 vit dans la region de pointeurs PARTAGEE de la session, que l'IPC bsd suivant
        // reutilise. On y relisait donc le sockaddr d'un connect ulterieur comme des descripteurs -> EBADF
        // sur tout le sondage -> la boucle d'evenements de gRPC se coince et le jeu reste au chargement.
        public byte[] PollInputSnapshot;

        public ServiceCtx(
            Switch device,
            KProcess process,
            IVirtualMemoryManager memory,
            KThread thread,
            IpcMessage request,
            IpcMessage response,
            BinaryReader requestData,
            BinaryWriter responseData)
        {
            Device = device;
            Process = process;
            Memory = memory;
            Thread = thread;
            Request = request;
            Response = response;
            RequestData = requestData;
            ResponseData = responseData;
        }
    }
}
