map_to_extern(extern_func::Ptr{wasm_func_t}) = wasm_func_as_extern(extern_func)
map_to_extern(other) = error("Type $(typeof(other)) is not supported")

mutable struct WasmInstance
    wasm_instance_ptr::Ptr{wasm_instance_t}
    wasm_module::WasmModule
    
    WasmInstance(wasm_instance_ptr::Ptr{wasm_instance_t}, wasm_module::WasmModule) = finalizer(new(wasm_instance_ptr, wasm_module)) do wasm_instance
        wasm_instance_delete(wasm_instance.wasm_instance_ptr)
    end
end
function WasmInstance(store::WasmStore, wasm_module::WasmModule)
    module_imports = imports(wasm_module)
    n_expected_imports = length(module_imports.wasm_imports)
    @assert n_expected_imports == 0 "No imports provided, expected $n_expected_imports"

    empty_imports = WasmPtrVec(wasm_extern_t)
    wasm_instance_ptr = wasm_instance_new(store.wasm_store_ptr, wasm_module.wasm_module_ptr, empty_imports, C_NULL)
    @assert wasm_instance_ptr != C_NULL "Failed to create WASM instance"
    WasmInstance(wasm_instance_ptr, wasm_module)
end
function WasmInstance(store::WasmStore, wasm_module::WasmModule, host_imports) where T
    externs_vec = WasmPtrVec(map(map_to_extern, host_imports))
    WasmInstance(store::WasmStore, wasm_module::WasmModule, externs_vec::WasmVec{wasm_extern_vec_t, Ptr{wasm_extern_t}})
end
function WasmInstance(store::WasmStore, wasm_module::WasmModule, externs_vec::WasmVec{wasm_extern_vec_t, Ptr{wasm_extern_t}})
    module_imports = imports(wasm_module)
    n_expected_imports = length(module_imports.wasm_imports)
    n_provided_imports = length(externs_vec)
    @assert n_expected_imports == n_provided_imports "$n_provided_imports imports provided, expected $n_expected_imports"

    wasm_instance_ptr = wasm_instance_new(store.wasm_store_ptr, wasm_module.wasm_module_ptr, externs_vec, C_NULL)
    @assert wasm_instance_ptr != C_NULL "Failed to create WASM instance"
    WasmInstance(wasm_instance_ptr, wasm_module)
end

Base.show(io::IO, ::WasmInstance) = print(io, "WasmInstance()")

# TODO: One for each exporttype_type?
mutable struct WasmExport
    # The wasm_exporttype_t refers to the export on the module side
    wasm_export_ptr::Ptr{wasm_exporttype_t}
    # The wasm_extern_t refers to the export on the instance side
    wasm_extern_ptr::Ptr{wasm_extern_t}
    wasm_instance::WasmInstance
    name::String

    function WasmExport(
        wasm_export_ptr::Ptr{wasm_exporttype_t}, 
        wasm_extern_ptr::Ptr{wasm_extern_t},
        wasm_instance::WasmInstance,
    )
        owned_wasm_export_ptr = wasm_exporttype_copy(wasm_export_ptr)
        @assert owned_wasm_export_ptr != C_NULL "Failed to copy WASM export"

        owned_wasm_extern_ptr = wasm_extern_copy(wasm_extern_ptr)
        @assert owned_wasm_extern_ptr != C_NULL "Failed to copy WASM extern"

        name_vec_ptr = wasm_exporttype_name(owned_wasm_export_ptr)
        name_vec = Base.unsafe_load(name_vec_ptr)
        name = unsafe_string(name_vec.data, name_vec.size)
        wasm_name_delete(name_vec_ptr)

        # TODO: Extract type here
        finalizer(new(owned_wasm_export_ptr,owned_wasm_extern_ptr, wasm_instance, name)) do wasm_export
            wasm_exporttype_delete(wasm_export.wasm_export_ptr)
            wasm_extern_delete(wasm_export.wasm_extern_ptr)
        end
    end
end

function (wasm_export::WasmExport)(args...)
    wasm_externtype_ptr = wasm_exporttype_type(wasm_export.wasm_export_ptr)
    @assert wasm_externtype_ptr != C_NULL "Failed to get export type for export $(wasm_export.name)"
    wasm_externkind = wasm_externtype_kind(wasm_externtype_ptr)
    @assert wasm_externkind == WASM_EXTERN_FUNC "Called export '$(wasm_export.name)' is not a function"

    extern_as_func = wasm_extern_as_func(wasm_export.wasm_extern_ptr)
    @assert extern_as_func != C_NULL "Can not use export $(wasm_export.name) as a function"
    
    params_arity = wasm_func_param_arity(extern_as_func)
    result_arity = wasm_func_result_arity(extern_as_func)

    provided_params = length(args)
    if params_arity != provided_params
        error("Wrong number of argument to function $(wasm_export.name), expected $params_arity, got $provided_params")
    end

    converted_args = collect(wasm_val_t, map(arg -> convert(wasm_val_t, arg), args))
    params_vec = WasmVec(converted_args)

    default_val = wasm_val_t(tuple(zeros(UInt8, 16)...))
    results_vec = WasmVec([default_val for _ in 1:result_arity])

    wasm_func_call(extern_as_func, params_vec, results_vec)

    collect(results_vec)
end

mutable struct WasmExports
    wasm_instance::WasmInstance
    wasm_exports::Vector{WasmExport}

    function WasmExports(wasm_instance::WasmInstance)
        exports = WasmPtrVec(wasm_exporttype_t)
        wasm_module_exports(wasm_instance.wasm_module.wasm_module_ptr, exports)
        externs = WasmPtrVec(wasm_extern_t)
        wasm_instance_exports(wasm_instance.wasm_instance_ptr, externs)
        @assert length(exports) == length(externs)

        exports_vector = map(a -> WasmExport(a..., wasm_instance), zip(exports, externs))

        new(wasm_instance, exports_vector)
    end
end
exports(instance::WasmInstance) = WasmExports(instance)

function Base.getproperty(wasm_exports::WasmExports, f::Symbol)
    if f ∈ fieldnames(WasmExports)
        return getfield(wasm_exports, f)
    end

    lookup_name = string(f)
    export_index = findfirst(wasm_export -> wasm_export.name == lookup_name, wasm_exports.wasm_exports)
    @assert export_index !== nothing "Export $f not found"

    wasm_exports.wasm_exports[export_index]
end