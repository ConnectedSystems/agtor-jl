using Mixers
using Agtor
using DataFrames
import Flatten
import Dates


abstract type AgParameter end

AgUnion = Union{Date, Int64, Float64, AgParameter}


@with_kw mutable struct ConstantParameter <: AgParameter
    name::String
    default_val::Any
    value::Any

    ConstantParameter(name, default_val) = new(name, default_val, default_val)
end

@with_kw mutable struct RealParameter <: AgParameter
    name::String
    min_val::Float64
    max_val::Float64
    default_val::Float64
    value::Float64

    RealParameter(name, min_val, max_val, value) = new(name, min_val, max_val, value, value)
    RealParameter(name, range_vals::Array, value) = new(name, range_vals..., value, value)
end


@doc """
    Categorical parameters.

    Min and max values will map to (integer) element position in an CategoricalArray.

    Sampling between the min and max values will be mapped to their categorical value in the given array
    using `floor()` of the Float value `x`.

    Valid values for the CategoricalParameter will therefore be: 
    `1 <= x < (n+1)`, where n is number of options.
"""
@with_kw mutable struct CategoricalParameter <: AgParameter
    name::String
    cat_val::CategoricalArray
    min_val::Int64
    max_val::Int64
    default_val::Any
    value::Any

    function CategoricalParameter(name::String, cat_val::CategoricalArray, value::Any)::CategoricalValue
        min_val = 1
        max_val = length(cat_val) + 1

        return new(name, cat_val, min_val, max_val, value, value)
    end

    function CategoricalParameter(name::String, cat_val::CategoricalArray, default_value::Any, value::Any)::CategoricalValue
        min_val = 1
        max_val = length(cat_val) + 1

        return new(name, cat_val, min_val, max_val, default_value, value)
    end
end

"""Setter for CategoricalParameter to handle float to categorical element position."""
function Base.setproperty!(cat::CategoricalParameter, v::Symbol, value)::Nothing
    if v == :value
        if value isa AbstractFloat || value isa Integer
            cat_pos = floor(Int, value)
            cat.value = cat.cat_val[cat_pos]
        elseif value isa String
            pos = cat.cat_val(findfirst(x-> x == value, cat.cat_val))
            if isnothing(pos)
                error("$(pos) is not a valid option for $(cat.name)")
            end

            cat.value = cat.cat_val[pos]
        else
            error("Type $(typeof(value)) is not a valid type option for $(cat.name), has to be Integer, Float or String")
        end
    else
        setfield!(f, Symbol(v), value)
    end

    return nothing
end


# Below is equivalent to defining methods for each operation, e.g:
#    function Base.:+(x::AgParameter, y::AgParameter) x.value + y.value end
for op = (:+, :-, :/, :*, :^)
    @eval Base.$op(x::AgParameter, y::AgParameter) = Base.$op(x.value, y.value)
end

for op = (:+, :-, :/, :*, :^)
    @eval Base.$op(x::Union{Int, Real}, y::AgParameter) = Base.$op(x, y.value)
end

for op = (:+, :-, :/, :*, :^)
    @eval Base.$op(x::AgParameter, y::Union{Int, Real}) = Base.$op(x.value, y)
end


function Base.:*(x::String, y::Union{ConstantParameter, CategoricalParameter}) x * y.value end

# function Base.convert(x::Type{Union{Float64, Int64}}, y::Agtor.RealParameter) convert(x, y.value) end
function Base.convert(x::Type{Any}, y::Agtor.ConstantParameter) convert(x, y.value) end


for op = (:Year, :Month, :Day)
    @eval Dates.$op(x::AgParameter) = Dates.$op(x.value)
end


"""Returns min/max values"""
function min_max(p::AgParameter)
    if is_const(p)
        return p.value
    end

    return p.min_val, p.max_val
end


"""Returns min/max values"""
function min_max(dataset::Dict)::Dict
    mm::Dict{Union{Dict, Symbol}, Union{Dict, Any}} = Dict()
    for (k, v) in dataset
        if v isa AgParameter
            mm[k] = min_max(v)
        else
            mm[k] = v
        end
    end

    return mm
end


"""
Generate AgParameter definitions.

Parameters
----------
prefix : str

dataset : Dict, of parameters for given component

Returns
----------
* Dict matching structure of dataset
"""
function generate_agparams(prefix::Union{String, Symbol}, dataset::Dict)::Dict{Symbol, Any}
    if "component" in keys(dataset)
        comp = dataset["component"]
        comp_name = dataset["name"]
        if prefix === ""
            prefix *= "$(comp)__$(comp_name)"
        else
            prefix *= "___$(comp)__$(comp_name)"
        end
    end

    created::Dict{Any, Any} = deepcopy(dataset)
    for (n, vals) in dataset
        var_id = prefix * "~$n"

        s = Symbol(n)
        pop!(created, n)

        if isa(vals, Dict)
            created[s] = generate_agparams(prefix, vals)
            continue
        elseif endswith(String(n), "_spec")
            # Recurse into other defined specifications
            tmp = load_yaml(vals)
            created[s] = generate_agparams(prefix, tmp)
            continue
        end

        if !in(vals[1], ["CategoricalParameter", "RealParameter", "ConstantParameter"])
            created[s] = vals
            continue
        end

        if isa(vals, Array)
            val_type, param_vals = vals[1], vals[2:end]

            def_val = param_vals[1]

            if length(unique(param_vals)) == 1
                created[s] = ConstantParameter(var_id, def_val)
                continue
            end

            valid_vals = param_vals[2:end]
            if val_type == "CategoricalParameter"
                valid_vals = categorical(valid_vals, ordered=true)
            end

            created[s] = eval(Symbol(val_type))(var_id, valid_vals, def_val)
        else
            created[s] = vals
        end
    end

    return created
end


function sample_params(dataset::Dict)
end


"""Extract parameter values from AgParameter"""
function extract_values(p::AgParameter; prefix::Union{String, Nothing}=nothing)::NamedTuple
    if !isnothing(prefix)
        name = prefix * p.name
    else
        name = p.name
    end

    if is_const(p)
        return (name=name, ptype=typeof(p), default=p.value, min_val=p.value, max_val=p.value)
    end

    return (name=name, ptype=typeof(p), default=p.default_val, min_val=p.min_val, max_val=p.max_val)
end


function collect_agparams!(dataset::Dict, store::Array; ignore::Union{Array, Nothing}=nothing)
    for (k, v) in dataset
        if !isnothing(ignore) && (k in ignore)
            continue
        end

        if v isa AgParameter && !is_const(v)
            push!(store, extract_values(v))
        elseif v isa Dict || v isa Array
            collect_agparams!(v, store; ignore=ignore)
        end
    end

    return DataFrame(store)
end


function collect_agparams!(dataset::Array, store::Array; ignore::Union{Array, Nothing}=nothing)
    for v in dataset
        if v isa AgParameter && !is_const(v)
            push!(store, extract_values(v))
        elseif v isa Dict || v isa Array
            collect_agparams!(v, store; ignore=ignore)
        end
    end
end


"""Extract parameter values from Dict specification."""
function collect_agparams(dataset::Dict; prefix::Union{String, Nothing}=nothing)::Dict
    mm::Dict{Symbol, Any} = Dict()
    for (k, v) in dataset
        if v isa AgParameter && !is_const(v)
            if !isnothing(prefix)
                name = prefix * v.name
            else
                name = v.name
            end
            mm[Symbol(name)] = extract_values(v; prefix=prefix)
        end
    end

    return mm
end


# """Extract parameter values from Dict specification and store in a common Dict."""
function collect_agparams!(dataset::Dict, mainset::Dict)::Nothing
    for (k, v) in dataset
        if Symbol(v.name) in mainset
            error("$(v.name) is already set!")
        end

        if v isa AgParameter && !is_const(v)
            mainset[Symbol(v.name)] = extract_values(v)
        end
    end
end


"""Checks if parameter is constant."""
function is_const(p::AgParameter)::Bool
    if (p isa ConstantParameter) || (value_range(p) == 0.0)
        return true
    end

    return false
end


"""Returns max - min, or 0.0 if no min value defined"""
function value_range(p::AgParameter)::Float64
    if hasproperty(p, :min_val) == false
        return 0.0
    end

    return p.max_val - p.min_val
end


"""Modify AgParameter name in place by adding a prefix."""
function add_prefix!(prefix::String, component)
    params = Flatten.flatten(component, AgParameter)
    for pr in params
        pr.name = prefix*pr.name
    end
end


"""
Usage:
    zone_dir = "data_dir/zones/"
    zone_specs = load_yaml(zone_dir)
    zone_params = generate_agparams("", zone_specs["Zone_1"])
    
    collated_specs = []
    collect_agparams!(zone_params, collated_specs; ignore=["crop_spec"])
    
    # Expect only CSV for now...
    climate_data::String = "data/climate/farm_climate_data.csv"
    if endswith(climate_data, ".csv")
        use_threads = Threads.nthreads() > 1
        climate_seq = DataFrame!(CSV.File(climate_data, threaded=use_threads, dateformat="dd-mm-YYYY"))
    else
        error("Currently, climate data can only be provided in CSV format")
    end

    climate::Climate = Climate(climate_seq)
    z1 = create(zone_params, climate)

    param_info = DataFrame(collated_specs)

    # Generate dataframe of samples
    samples = sample(param_info, 1000, sampler)  # where sampler is some function

    # Update z1 components with values found in first row
    set_params!(z1, samples[1])
"""
function set_params!(comp, sample)
    # entries = map(ap -> param_info(ap), Flatten.flatten(test_irrig, Agtor.AgParameter))
    for f_name in fieldnames(typeof(comp))
        tmp_f = getfield(comp, f_name)
        if tmp_f isa Array
            arr_type = eltype(tmp_f)
            tmp_flat = reduce(vcat, Flatten.flatten(tmp_f, Array{arr_type}))
            for i in tmp_flat
                set_params!(i, sample)
            end
        elseif isa(tmp_f, AgComponent) || isa(tmp_f, Dict)
            set_params!(tmp_f, sample)
        elseif tmp_f isa AgParameter
            set_params!(tmp_f, sample)
        end
    end
end


function set_params!(comp::Dict, sample)
    for (k,v) in comp
        set_params!(v, sample)
    end
end


function set_params!(p::AgParameter, sample)
    p_name::String = p.name
    if p_name in names(sample)
        p.value = sample[p_name]
    end
end


function set_params!(p::AgParameter, sample::Union{Dict,NamedTuple})
    p_name::Symbol = Symbol(p.name)
    if p_name in keys(sample)
        p.value = sample[p_name]
    end
end


function update_model(comp, sample)
    comp = deepcopy(comp)
    set_params!(comp, sample)

    return comp
end
