using Ryujinx.Common;
using Ryujinx.Memory;
using System;
using System.Diagnostics;
using System.Runtime.Versioning;
using System.Threading;

namespace Ryujinx.Cpu.LightningJit.Cache
{
    [SupportedOSPlatform("macos")]
    [SupportedOSPlatform("ios")]
    class DualMappedNoWxCache : IDisposable
    {
        private const int CodeAlignment = 4; // Bytes.
        private static readonly ulong SharedCacheSize = DualMappedJitAllocator.hasTXM ? (ulong)512 * 1024 * 1024 : 1024 * 1024 * 1024;

        private class MemoryCache : IDisposable
        {
            private readonly DualMappedJitAllocator _allocator;
            private readonly CacheMemoryAllocator _cacheAllocator;
            public IntPtr RwPointer => _allocator.RwPtr;
            public IntPtr RxPointer => _allocator.RxPtr;

            public MemoryCache(DualMappedJitAllocator alloc, ulong size)
            {
                _allocator = alloc;
                _cacheAllocator = new((int)size);
            }

            public int Allocate(int codeSize)
            {
                codeSize = AlignCodeSize(codeSize);

                int allocOffset = _cacheAllocator.Allocate(codeSize);

                if (allocOffset < 0)
                {
                    throw new OutOfMemoryException("JIT Cache exhausted.");
                }

                return allocOffset;
            }

            public int AllocateAligned(int codeSize, int alignment)
            {
                codeSize = AlignCodeSize(codeSize);

                int allocOffset = _cacheAllocator.AllocateAligned(codeSize, alignment);

                if (allocOffset < 0)
                {
                    throw new OutOfMemoryException("JIT Cache exhausted.");
                }

                return allocOffset;
            }

            public void SysIcacheInvalidate(int offset, int size)
            {
                if (OperatingSystem.IsMacOS() || OperatingSystem.IsIOS())
                {
                    JitSupportDarwin.SysIcacheInvalidate(_allocator.RxPtr + offset, size);
                }
                else
                {
                    throw new PlatformNotSupportedException();
                }
            }

            private static int AlignCodeSize(int codeSize)
            {
                return checked(codeSize + (CodeAlignment - 1)) & ~(CodeAlignment - 1);
            }

            protected virtual void Dispose(bool disposing)
            {
                if (disposing)
                {
                    _allocator.Dispose();
                    _cacheAllocator.Clear();
                }
            }

            public void Dispose()
            {
                Dispose(disposing: true);
                GC.SuppressFinalize(this);
            }
        }

        private readonly Translator _translator;
        private MemoryCache _sharedCache;
        private static DualMappedJitAllocator _sharedCacheAlloc;
        private readonly Lock _lock = new();

        public DualMappedNoWxCache(Translator translator)
        {
            _translator = translator;
            _sharedCache = new(_sharedCacheAlloc, SharedCacheSize);
        }

        public static void InitMemoryCache() 
        {
            if (_sharedCacheAlloc != null)
                return;

            _sharedCacheAlloc = new(SharedCacheSize);
        }

        public unsafe nint Map(ReadOnlySpan<byte> code, ulong guestAddress, ulong guestSize)
        {
            if (TryGetCachedFunction(guestAddress, out nint funcPtr))
            {
                return funcPtr;
            }

            lock (_lock)
            {
                if (TryGetSharedFunction(guestAddress, out funcPtr))
                {
                    return funcPtr;
                }

                int funcOffset = _sharedCache.Allocate(code.Length);

                funcPtr = _sharedCache.RwPointer + funcOffset;
                code.CopyTo(new Span<byte>((void*)funcPtr, code.Length));
                _sharedCache.SysIcacheInvalidate(funcOffset, code.Length);

                funcPtr = _sharedCache.RxPointer + funcOffset;
                RegisterFunction(guestAddress, new TranslatedFunction(funcPtr, guestSize));

                return funcPtr;
            }
        }

        public unsafe nint MapPageAligned(ReadOnlySpan<byte> code)
        {
            lock (_lock)
            {
                int sizeAligned = BitUtils.AlignUp(code.Length, (int)MemoryBlock.GetPageSize());
                int funcOffset = _sharedCache.AllocateAligned(sizeAligned, (int)MemoryBlock.GetPageSize());

                Debug.Assert((funcOffset & ((int)MemoryBlock.GetPageSize() - 1)) == 0);

                nint funcPtr = _sharedCache.RwPointer + funcOffset;
                code.CopyTo(new Span<byte>((void*)funcPtr, code.Length));
                funcPtr = _sharedCache.RxPointer + funcOffset;

                _sharedCache.SysIcacheInvalidate(funcOffset, sizeAligned);

                return funcPtr;
            }
        }

        internal bool TryGetCachedFunction(ulong guestAddress, out nint funcPtr)
        {
            return TryGetSharedFunction(guestAddress, out funcPtr);
        }

        private bool TryGetSharedFunction(ulong guestAddress, out nint funcPtr)
        {
            if (_translator.Functions.TryGetValue(guestAddress, out TranslatedFunction function))
            {
                funcPtr = function.FuncPointer;

                return true;
            }

            funcPtr = nint.Zero;

            return false;
        }

        private void RegisterFunction(ulong address, TranslatedFunction func)
        {
            TranslatedFunction oldFunc = _translator.Functions.GetOrAdd(address, func.GuestSize, func);

            Debug.Assert(oldFunc == func);

            _translator.RegisterFunction(address, func);
        }

        protected virtual void Dispose(bool disposing)
        {
        }

        public void Dispose()
        {
            Dispose(disposing: true);
            GC.SuppressFinalize(this);
        }
    }
}
