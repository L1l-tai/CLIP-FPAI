"""
A self-contained script that both provides the iCraft library proxy
and acts as a launcher to run user scripts under this proxy.

This script merges the logic from the original `icraft_proxy` directory
and the `run_with_proxy.py` launcher.

To use it, 
1. Place this script in your project directory.
    for example,
    +---modelzoo_utils
|   |   setup.py
    |   +---pyrtutils
|   |   |   calctime_utils.py
    ...
    +---pyrt
    |       time_results.xlsx
    |       UNet_psin.py
    |       icraft_launcher.py
2. Run:
  python icraft_launcher.py <your_script.py> [args...]
"""
import multiprocessing
import atexit
import sys
import inspect
import runpy
import os
import traceback
import uuid
import pkgutil
import importlib
import pickle
import io
import numpy as np
from types import ModuleType

# ==============================================================================
# Part 1: Proxy classes (from proxies.py)
# ==============================================================================
_remote_type_cache = {}

def get_remote_type(conn, obj_id, class_name):
    cache_key = (id(conn), obj_id)
    if cache_key in _remote_type_cache:
        return _remote_type_cache[cache_key]

    def __init__(self, *args, **kwargs):
        remote_class_proxy = type(self)
        packed_args = _pack(args)
        packed_kwargs = _pack(kwargs)
        remote_class_proxy._conn.send((remote_class_proxy._obj_id, '__call_self__', (packed_args, packed_kwargs), {}))
        result_type, payload = remote_class_proxy._conn.recv()
        if result_type == '__proxy__':
            _, new_obj_id, new_class_name = payload
            Proxy.__init__(self, remote_class_proxy._conn, new_obj_id, new_class_name)
        else:
            Proxy._handle_result(remote_class_proxy, result_type, payload)

    class RemoteTypeMeta(type):
        def __instancecheck__(cls, instance):
            if not isinstance(instance, Proxy) or instance._obj_id is None: return False
            cls._conn.send((cls._obj_id, '__isinstancecheck__', (instance._obj_id,), {}))
            result_type, payload = cls._conn.recv()
            if result_type == '__result__': return payload
            print(f"--- [icraft_proxy] isinstance check failed: {result_type} ---", file=sys.stderr)
            print(payload, file=sys.stderr)
            return False
        def __getattr__(cls, name):
            if name.startswith('__') and name.endswith('__'): raise AttributeError(f"RemoteType has no attribute '{name}'")
            cls._conn.send((cls._obj_id, '__getattr__', (name,), {}))
            result_type, payload = cls._conn.recv()
            if result_type == '__callable__':
                def proxied_static_function(*args, **kwargs):
                    packed_args = _pack(args)
                    packed_kwargs = _pack(kwargs)
                    cls._conn.send((cls._obj_id, '__call__', (name, packed_args, packed_kwargs), {}))
                    call_result_type, call_payload = cls._conn.recv()
                    return Proxy._handle_result(cls, call_result_type, call_payload)
                return proxied_static_function
            else:
                return Proxy._handle_result(cls, result_type, payload)
        def __repr__(cls):
            return f"<RemoteType proxy for '{cls._class_name}'>"

    new_type = RemoteTypeMeta(f"Remote<{class_name}>", (Proxy,), {"__init__": __init__})
    new_type._conn = conn
    new_type._obj_id = obj_id
    new_type._class_name = class_name
    _remote_type_cache[cache_key] = new_type
    return new_type

def _pack(item):
    if isinstance(item, Proxy): return ('__proxy_ref__', item._obj_id)
    if isinstance(item, type) and hasattr(item, '_obj_id'): return ('__proxy_ref__', item._obj_id)
    if isinstance(item, SubmoduleProxy): return ('__proxy_ref__', item._obj_id)
    if isinstance(item, list): return [_pack(x) for x in item]
    if isinstance(item, tuple): return tuple(_pack(x) for x in item)
    if isinstance(item, dict): return {k: _pack(v) for k, v in item.items()}
    return item

class Proxy:
    def __init__(self, conn, obj_id, class_name=None):
        object.__setattr__(self, '_conn', conn)
        object.__setattr__(self, '_obj_id', obj_id)
        object.__setattr__(self, '_class_name', class_name)
    def __call__(self, *args, **kwargs):
        packed_args = _pack(args)
        packed_kwargs = _pack(kwargs)
        self._conn.send((self._obj_id, '__call_self__', (packed_args, packed_kwargs), {}))
        result_type, payload = self._conn.recv()
        return self._handle_result(result_type, payload)
    def __getattr__(self, name):
        if name.startswith('__'): raise AttributeError(f"Proxy has no attribute '{name}'")
        self._conn.send((self._obj_id, '__getattr__', (name,), {}))
        result_type, payload = self._conn.recv()
        if result_type == '__callable__':
            def proxied_function(*args, **kwargs):
                if name in {'dump', 'save', 'write'} and args and isinstance(args[0], io.IOBase):
                    local_file_handle, other_args = args[0], args[1:]
                    packed_other_args, packed_kwargs = _pack(other_args), _pack(kwargs)
                    self._conn.send((self._obj_id, '__call_and_get_bytes__', (name, packed_other_args, packed_kwargs), {}))
                    result_type, payload = self._conn.recv()
                    if result_type == '__result__':
                        local_file_handle.write(payload)
                        return None
                    else:
                        return self._handle_result(result_type, payload)
                packed_args, packed_kwargs = _pack(args), _pack(kwargs)
                self._conn.send((self._obj_id, '__call__', (name, packed_args, packed_kwargs), {}))
                call_result_type, call_payload = self._conn.recv()
                return self._handle_result(call_result_type, call_payload)
            return proxied_function
        else:
            return self._handle_result(result_type, payload)
    def _handle_result(self, result_type, payload):
        if result_type == '__proxy__':
            _, obj_id, class_name = payload
            return Proxy(self._conn, obj_id, class_name)
        elif result_type == '__remote_type__':
            _, obj_id, class_name = payload
            return get_remote_type(self._conn, obj_id, class_name)
        elif result_type == '__result__': return payload
        elif result_type == '__exception__':
            print("--- Exception in worker process ---", file=sys.stderr); print(payload, file=sys.stderr); print("-----------------------------------", file=sys.stderr)
            raise RuntimeError("An exception occurred in the worker process.")
        elif result_type == '__critical_exception__':
            print("--- CRITICAL, UNRECOVERABLE EXCEPTION IN WORKER PROCESS ---", file=sys.stderr)
            print("The worker process has terminated unexpectedly.", file=sys.stderr); print("--- Reason ---", file=sys.stderr); print(payload, file=sys.stderr)
            print("---------------------------------------------------------", file=sys.stderr)
            raise RuntimeError("The worker process died. See details above.")
        else: raise TypeError(f"Unknown result type from worker: {result_type}")
    def __getitem__(self, key):
        self._conn.send((self._obj_id, '__getitem__', (key,), {})); result_type, payload = self._conn.recv(); return self._handle_result(result_type, payload)
    def __str__(self):
        self._conn.send((self._obj_id, '__str__', (), {})); result_type, payload = self._conn.recv()
        if result_type == '__result__': return payload
        return self.__repr__()
    def __len__(self):
        self._conn.send((self._obj_id, '__len__', (), {})); result_type, payload = self._conn.recv(); return self._handle_result(result_type, payload)
    def __bool__(self):
        if self._obj_id is None: return False
        self._conn.send((self._obj_id, '__bool__', (), {})); result_type, payload = self._conn.recv(); return self._handle_result(result_type, payload)
    def __repr__(self): return f"<Proxy for object '{self._obj_id}' of class '{self._class_name}'>"
    def __setattr__(self, name, value): raise NotImplementedError("Setting attributes on a proxy is not yet supported.")
    def __array__(self, dtype=None):
        self._conn.send((self._obj_id, '__to_numpy__', (), {})); result_type, payload = self._conn.recv(); numpy_array = self._handle_result(result_type, payload)
        if dtype: return numpy_array.astype(dtype)
        return numpy_array
    def to_numpy(self):
        self._conn.send((self._obj_id, '__to_numpy__', (), {})); result_type, payload = self._conn.recv(); return self._handle_result(result_type, payload)
    def __iter__(self):
        self._conn.send((self._obj_id, '__iter__', (), {})); result_type, payload = self._conn.recv()
        iterator_proxy = self._handle_result(result_type, payload)
        return ProxyIterator(self._conn, iterator_proxy)

class ProxyIterator:
    def __init__(self, conn, iterator_proxy):
        self._conn = conn
        self._iterator_proxy = iterator_proxy
    def __iter__(self): return self
    def __next__(self):
        self._conn.send((self._iterator_proxy._obj_id, '__next__', (), {}))
        result_type, payload = self._conn.recv()
        if result_type == '__stop_iteration__': raise StopIteration
        return self._iterator_proxy._handle_result(result_type, payload)

class SubmoduleProxy:
    def __init__(self, conn, module_name, members=None):
        object.__setattr__(self, '_conn', conn)
        object.__setattr__(self, '_module_name', module_name)
        object.__setattr__(self, '_obj_id', f'module:{module_name}')
        object.__setattr__(self, '_members', members or [])
    def __getattr__(self, name):
        if name.startswith('__'): raise AttributeError(f"SubmoduleProxy has no attribute '{name}'")
        self._conn.send((self._obj_id, '__getattr__', (name,), {}))
        result_type, payload = self._conn.recv()
        if result_type == '__callable__':
            def proxied_function(*args, **kwargs):
                packed_args, packed_kwargs = _pack(args), _pack(kwargs)
                self._conn.send((self._obj_id, '__call__', (name, packed_args, packed_kwargs), {}))
                call_result_type, call_payload = self._conn.recv()
                return self._handle_result(call_result_type, call_payload)
            return proxied_function
        else:
            return self._handle_result(result_type, payload)
    def _handle_result(self, result_type, payload):
        return Proxy._handle_result(self, result_type, payload)
    def __repr__(self): return f"<SubmoduleProxy for '{self._module_name}'>"
    def __dir__(self): return self._members

# ==============================================================================
# Part 2: Worker logic (from worker.py)
# ==============================================================================
class _ProxyWorker:
    def __init__(self):
        self._modules, self._submodule_names, self._object_registry = {'icraft': icraft}, [], {}
        if hasattr(icraft, '__path__'):
            for _, name, _ in pkgutil.iter_modules(icraft.__path__):
                try:
                    full_name = f"icraft.{name}"; module = importlib.import_module(full_name)
                    self._modules[name] = module; self._submodule_names.append(name)
                except Exception as e:
                    # The user has indicated these modules (e.g., adapt, codegen) fail to load
                    # but are not used. We can safely ignore the import error and not print anything.
                    pass
                    # print(f"Worker: Failed to import submodule {full_name}: {e}", file=sys.stderr)
    def _unpack(self, item):
        if isinstance(item, tuple) and len(item) == 2 and isinstance(item[0], str) and item[0] == '__proxy_ref__': return self._find_target(item[1])
        if isinstance(item, list): return [self._unpack(x) for x in item]
        if isinstance(item, tuple): return tuple(self._unpack(x) for x in item)
        if isinstance(item, dict): return {k: self._unpack(v) for k, v in item.items()}
        return item
    def _send_result(self, conn, result):
        try:
            pickle.dumps(result); conn.send(('__result__', result))
        except (TypeError, pickle.PicklingError):
            new_id = str(uuid.uuid4()); self._object_registry[new_id] = result
            conn.send(('__proxy__', (None, new_id, result.__class__.__name__)))
    def run(self, conn):
        submodule_exports = {}
        for name, module in self._modules.items():
            if name != 'icraft' and not name.startswith('_'):
                try: submodule_exports[name] = [member for member in dir(module) if not member.startswith('_')]
                except Exception: submodule_exports[name] = []
        conn.send(submodule_exports)
        while True:
            try:
                obj_id, command, args, kwargs = conn.recv()
                if command == '__close__': break
                target = self._find_target(obj_id)
                if target is None:
                    if obj_id is not None: raise ValueError(f"Object or module with id/spec '{obj_id}' not found.")
                    target = self._modules['icraft']
                if command == '__getattr__':
                    attr = getattr(target, args[0])
                    if inspect.isclass(attr) and hasattr(attr, '__module__') and 'icraft' in attr.__module__:
                        new_id = str(uuid.uuid4()); self._object_registry[new_id] = attr
                        conn.send(('__remote_type__', (None, new_id, attr.__name__)))
                    elif callable(attr): conn.send(('__callable__', None))
                    else: self._send_result(conn, attr)
                elif command == '__getitem__': self._send_result(conn, target[args[0]])
                elif command == '__str__': conn.send(('__result__', str(target)))
                elif command == '__len__': conn.send(('__result__', len(target)))
                elif command == '__isinstancecheck__': conn.send(('__result__', isinstance(self._find_target(args[0]), target)))
                elif command == '__call_and_get_bytes__':
                    method_name, other_args, other_kwargs = args
                    unpacked_args, unpacked_kwargs = self._unpack(other_args), self._unpack(other_kwargs)
                    buffer = io.BytesIO(); getattr(target, method_name)(buffer, *unpacked_args, **unpacked_kwargs)
                    buffer.seek(0); conn.send(('__result__', buffer.read()))
                elif command == '__bool__': conn.send(('__result__', bool(target)))
                elif command == '__iter__': self._send_result(conn, iter(target))
                elif command == '__next__':
                    try: self._send_result(conn, next(target))
                    except StopIteration: conn.send(('__stop_iteration__', None))
                elif command == '__to_numpy__':
                    try:
                        if hasattr(target, 'to_numpy'): numpy_array = target.to_numpy()
                        elif hasattr(target, 'numpy'): numpy_array = target.numpy()
                        else: numpy_array = np.array(target)
                        conn.send(('__result__', numpy_array))
                    except Exception: conn.send(('__exception__', traceback.format_exc()))
                elif command == '__call_self__':
                    unpacked_args, unpacked_kwargs = self._unpack(args[0]), self._unpack(args[1])
                    self._send_result(conn, target(*unpacked_args, **unpacked_kwargs))
                elif command == '__call__':
                    method_name, method_args, method_kwargs = args
                    unpacked_args, unpacked_kwargs = self._unpack(method_args), self._unpack(method_kwargs)
                    self._send_result(conn, getattr(target, method_name)(*unpacked_args, **unpacked_kwargs))
                else: self._send_result(conn, getattr(target, command)(*args, **kwargs))
            except EOFError: break
            except BaseException: conn.send(('__critical_exception__', traceback.format_exc()))
        conn.close()
    def _find_target(self, obj_id):
        if isinstance(obj_id, str) and obj_id.startswith('module:'): return self._modules.get(obj_id.split(':', 1)[1])
        if isinstance(obj_id, str) and obj_id.startswith('class:'):
            parts = obj_id.split(':', 1)[1].split('.'); module_name, class_name = parts[0], parts[1]
            module = self._modules.get(module_name)
            return getattr(module, class_name, None) if module else None
        if obj_id is None: return self._modules['icraft']
        else: return self._object_registry.get(obj_id)

def _proxy_worker_main(conn):
    """Entry point for the worker process. Imports real icraft and runs."""
    # This global is required for the exec'd code in _ProxyWorker's __init__
    global icraft
    try:
        # The real icraft module is imported only inside the worker process.
        import icraft
    except ImportError:
        print("Worker Error: The real 'icraft' library could not be imported.", file=sys.stderr)
        print("Please ensure it is in Python's path in the worker's environment.", file=sys.stderr)
        conn.send(('__critical_exception__', traceback.format_exc()))
        conn.close()
        sys.exit(1)
    
    worker_instance = _ProxyWorker()
    worker_instance.run(conn)

# ==============================================================================
# Part 3: Proxy initialization (from __init__.py)
# ==============================================================================
class ProxyModule(ModuleType):
    def __init__(self, proxy):
        super().__init__(f"icraft.{proxy._module_name}")
        object.__setattr__(self, "_proxy", proxy); object.__setattr__(self, "__path__", [])
    def __getattr__(self, name): return getattr(self._proxy, name)
    def __dir__(self): return self._proxy.__dir__()

_worker_process, _conn, _submodule_proxies = None, None, {}

def _start_worker():
    global _worker_process, _conn, _submodule_proxies
    # Do not start if we are the worker or if it's already running.
    if "--icraft-proxy-worker" in sys.argv or _worker_process is not None: return
    
    try: multiprocessing.set_start_method("spawn", force=True)
    except RuntimeError: pass
    
    parent_conn, child_conn = multiprocessing.Pipe()
    
    # The worker process re-executes this same script with a special flag.
    _worker_process = multiprocessing.Process(
        target=_proxy_worker_main, 
        args=(child_conn,),
    )
    _worker_process.daemon = True
    _worker_process.start()
    
    _conn = parent_conn
    
    # Receive the submodule exports with members from the worker
    submodule_exports = _conn.recv()
    
    # Create proxies and inject fake modules into sys.modules
    for name, members in submodule_exports.items():
        proxy = SubmoduleProxy(_conn, name, members)
        _submodule_proxies[name] = proxy
        full_module_name = f'icraft.{name}'
        sys.modules[full_module_name] = ProxyModule(proxy)

def _get_conn():
    if (_worker_process is None or not _worker_process.is_alive()) and "--icraft-proxy-worker" not in sys.argv:
        _start_worker()
    return _conn

class ModuleProxy:
    def __getattr__(self, name):
        if name.startswith('__'): raise AttributeError(f"Module proxy has no attribute '{name}'")
        if "--icraft-proxy-worker" in sys.argv:
            raise RuntimeError("Cannot use the proxy within the worker process.")
        
        def module_function(*args, **kwargs):
            conn = _get_conn()
            conn.send((None, name, args, kwargs)); result_type, payload = conn.recv()
            if result_type == '__proxy__':
                _, obj_id, class_name = payload; return Proxy(conn, obj_id, class_name)
            elif result_type == '__result__':
                return payload
            elif result_type == '__exception__':
                print("--- Exception in worker process ---", file=sys.stderr); print(payload, file=sys.stderr); print("-----------------------------------", file=sys.stderr)
                raise RuntimeError("An exception occurred in the worker process.")
            else:
                raise TypeError(f"Unknown result type from worker: {result_type}")
        return module_function

_module_proxy = ModuleProxy()

# This is the new `icraft` module object that the user script will see.
this_module = sys.modules[__name__]

def __getattr__(name):
    # If we are in the worker, do nothing.
    if "--icraft-proxy-worker" in sys.argv:
        raise AttributeError()

    # Ensure the worker connection is established and submodules are known.
    if not _submodule_proxies:
        _get_conn()

    # If the requested attribute is one of the discovered submodules, return its proxy.
    if name in _submodule_proxies:
        return _submodule_proxies[name]

    # If the attribute is a special dunder name, a function we need to expose from
    # the launcher itself (like 'init'), or the main launcher function,
    # then get it from this module directly to avoid recursion.
    if name.startswith('__') and name.endswith('__') or \
       name in {'init', 'main_launcher', '_proxy_worker_main'}:
        # Use object.__getattribute__ to bypass our custom __getattr__ and prevent recursion.
        return object.__getattribute__(this_module, name)

    # For all other attributes, assume it's a top-level function in the real 'icraft'
    # module and delegate the call to the module proxy.
    return getattr(_module_proxy, name)

def __dir__():
    if not _submodule_proxies: _get_conn()
    return list(_submodule_proxies.keys())

@atexit.register
def _cleanup():
    global _worker_process, _conn
    if _conn:
        try: _conn.send((None, '__close__', [], {}))
        except (BrokenPipeError, EOFError): pass
        _conn.close(); _conn = None
    if _worker_process:
        _worker_process.join(timeout=2)
        if _worker_process.is_alive(): _worker_process.terminate()
        _worker_process = None

def init():
    """Explicitly starts the worker process."""
    _get_conn()

# ==============================================================================
# Part 4: Launcher logic (from run_with_proxy.py)
# ==============================================================================
def main_launcher():
    """The main entry point, executed only in the parent process."""
    # 1. Initialize the proxy and start the worker.
    init()
    
    # 2. Place our loaded proxy module into the system's module cache.
    sys.modules['icraft'] = this_module
    
    # 3. Check for a script to run.
    if len(sys.argv) < 2:
        print(f"Usage: python {sys.argv[0]} <your_script.py> [args...]", file=sys.stderr)
        sys.exit(1)
        
    script_path = sys.argv[1]
    
    # Set the CWD to the target script's directory.
    script_dir = os.path.dirname(os.path.abspath(script_path))
    os.chdir(script_dir)
    
    # 4. Adjust sys.argv so the target script thinks it's the main script.
    sys.argv = sys.argv[1:]
    
    # 5. Use runpy to execute the application script.
    runpy.run_path(script_path, run_name='__main__')

if __name__ == '__main__':
    # The original script, `run_with_proxy.py`, had no special logic for being a worker.
    # It always acted as the launcher. We will replicate that behavior.
    # The `_proxy_worker_main` function serves as the entry point for the child process,
    # and it is called directly by `multiprocessing.Process`, not via this __main__ block.
    main_launcher()