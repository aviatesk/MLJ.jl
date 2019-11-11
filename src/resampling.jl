## RESAMPLING STRATEGIES

abstract type ResamplingStrategy <: MLJType end
show_as_constructed(::Type{<:ResamplingStrategy}) = true

# resampling strategies are `==` if they have the same type and their
# field values are `==`:
function ==(s1::S, s2::S) where S <: ResamplingStrategy
    return all(getfield(s1, fld) == getfield(s2, fld) for fld in fieldnames(S))
end

train_test_pairs(s::ResamplingStrategy, rows, X, y, w) =
    train_test_pairs(s, rows, X, y)
train_test_pairs(s::ResamplingStrategy, rows, X, y) =
    train_test_pairs(s, rows)

"""
    Holdout(; fraction_train=0.7,
              shuffle=false,
              rng=Random.GLOBAL_RNG)

Single train-test split with a (randomly selected) portion of the
data being selected for training and the rest for testing.

If `rng` is an integer, then `MersenneTwister(rng)` is the random
number generator used for shuffling rows. Otherwise some `AbstractRNG`
object is expected.

"""
struct Holdout <: ResamplingStrategy
    fraction_train::Float64
    shuffle::Bool
    rng::Union{Int,AbstractRNG}

    function Holdout(fraction_train, shuffle, rng)
        0 < fraction_train < 1 ||
            error("`fraction_train` must be between 0 and 1.")
        return new(fraction_train, shuffle, rng)
    end
end

# Keyword Constructor
function Holdout(; fraction_train::Float64=0.7,
                   shuffle::Bool=false,
                   rng::Union{Int,AbstractRNG}=Random.GLOBAL_RNG)
    Holdout(fraction_train, shuffle, rng)
end


function train_test_pairs(holdout::Holdout, rows)
    if holdout.rng isa Integer
        rng = MersenneTwister(holdout.rng)
    else
        rng = holdout.rng
    end
    train, test = partition(rows, holdout.fraction_train,
                             shuffle=holdout.shuffle, rng=rng)
    return [(train, test),]
end


"""
    CV(; nfolds=6,  shuffle=false, rng=Random.GLOBAL_RNG)

Cross validation resampling where the data is (randomly) partitioned
in `nfolds` folds and the model is evaluated `nfolds` times, each time
taking one fold for testing and the remaining folds for training.

For instance, if `nfolds=3` then the data will be partitioned in three
folds A, B and C and the model will be trained three times, first with
A and B and tested on C, then on A, C and tested on B and finally on
B, C and tested on A.

If `rng` is an integer, then `MersenneTwister(rng)` is the random
number generator used for shuffling rows. Otherwise some `AbstractRNG`
object is expected.

"""
struct CV <: ResamplingStrategy
    nfolds::Int
    shuffle::Bool
    rng::Union{Int,AbstractRNG}
    function CV(nfolds, shuffle, rng)
        nfolds > 1 || error("Must have nfolds > 1. ")
        return new(nfolds, shuffle, rng)
    end
end

# Constructor with keywords
CV(; nfolds::Int=6,  shuffle::Bool=false,
   rng::Union{Int,AbstractRNG}=Random.GLOBAL_RNG) =
       CV(nfolds, shuffle, rng)

function train_test_pairs(cv::CV, rows)
    if cv.rng isa Integer
        rng = MersenneTwister(cv.rng)
    else
        rng = cv.rng
    end

    n_observations = length(rows)
    nfolds = cv.nfolds

    if cv.shuffle
        rows=shuffle!(rng, collect(rows))
    end

    # number of observations per fold
    k = floor(Int, n_observations/nfolds)
    k > 0 || error("Inusufficient data for $nfolds-fold cross-validation.\n"*
                   "Try reducing nfolds. ")

    # define the (trainrows, testrows) pairs:
    firsts = 1:k:((nfolds - 1)*k + 1) # itr of first `test` rows index
    seconds = k:k:(nfolds*k)          # itr of last  `test` rows index
    ret = map(1:nfolds) do k
        f = firsts[k]
        s = seconds[k]
        return (vcat(rows[1:(f - 1)], rows[(s + 1):end]), # trainrows
                rows[f:s])                               # testrows
    end

    return ret
end


## EVALUATION METHODS

function _check_measure(model, measure, y, operation, override)

    override && (return nothing)

    T = scitype(y)

    T == Unknown && (return nothing)
    target_scitype(measure) == Unknown && (return nothing)
    prediction_type(measure) == :unknown && (return nothing)

    avoid = "\nTo override measure checks, set check_measure=false. "

    T <: target_scitype(measure) ||
        throw(ArgumentError(
            "\nscitype of target = $T but target_scitype($measure) = "*
            "$(target_scitype(measure))."*avoid))

    if model isa Probabilistic
        if operation == predict
            if prediction_type(measure) != :probabilistic
                suggestion = ""
                if target_scitype(measure) <: Finite
                    suggestion = "\nPerhaps you want to set operation="*
                    "predict_mode. "
                elseif target_scitype(measure) <: Continuous
                    suggestion = "\nPerhaps you want to set operation="*
                    "predict_mean or operation=predict_median. "
                else
                    suggestion = ""
                end
                throw(ArgumentError(
                   "\n$model <: Probabilistic but prediction_type($measure) = "*
                      ":$(prediction_type(measure)). "*suggestion*avoid))
            end
        end
    end

    model isa Deterministic && prediction_type(measure) != :deterministic &&
        throw(ArgumentError("$model <: Deterministic but "*
                            "prediction_type($measure) ="*
              ":$(prediction_type(measure))."*avoid))

    return nothing

end

function _process_weights_measures(weights, measures, mach,
                                   operation, verbosity, check_measure)

    if measures === nothing
        candidate = default_measure(mach.model)
        candidate ===  nothing && error("You need to specify measure=... ")
        _measures = [candidate, ]
    elseif !(measures isa AbstractVector)
        _measures = [measures, ]
    else
        _measures = measures
    end

    y = mach.args[2]

    [ _check_measure(mach.model, m, y, operation, !check_measure)
     for m in _measures ]

    if weights != nothing
        weights isa AbstractVector{<:Real} ||
            throw(ArgumentError("`weights` must be a `Real` vector."))
        length(weights) == nrows(y) ||
            throw(DimensionMismatch("`weights` and target "*
                                    "have different lengths. "))
        _weights = weights
    elseif  length(mach.args) == 3
        verbosity < 1 ||
            @info "Passing machine sample weights to any supported measures. "
        _weights = mach.args[3]
    else
        _weights = weights
    end

    return _weights, _measures

end

"""
    evaluate!(mach,
              resampling=CV(),
              measure=nothing,
              weights=nothing,
              operation=predict,
              acceleration=DEFAULT_RESOURCE[],
              force=false,
              verbosity=1)

Estimate the performance of a machine `mach` wrapping a supervised
model in data, using the specified `resampling` strategy (defaulting
to 6-fold cross-validation) and `measure`, which can be a single
measure or vector.

Do `subtypes(MLJ.ResamplingStrategy)` to obtain a list of available resampling
strategies. If `resampling` is not an object of type
`MLJ.ResamplingStrategy`, then a vector of pairs (of the form
`(train_rows, test_rows)` is expected. For example, setting

    resampling = [(1:100), (101:200)),
                   (101:200), (1:100)]

gives two-fold cross-validation using the first 200 rows of data.

If `resampling isa MLJ.ResamplingStrategy` then one may optionally
restrict the data used in evaluation by specifying `rows`.

An optional `weights` vector may be passed for measures that support
sample weights (`MLJ.supports_weights(measure) == true`), which is
ignored by those that don't. 

*Important:* If `mach` already wraps sample weights `w` (as in `mach =
machine(model, X, y, w)`) then these weights, which are used for
*training*, are automatically passed to the measures for
evaluation. However, for evaluation purposes, any `weights` specified
as a keyword argument will take precedence over `w`.

User-defined measures are supported; see the manual for details.

If no measure is specified, then `default_measure(mach.model)` is
used, unless this default is `nothing` and an error is thrown.

The `acceleration` keyword argument is used to specify the compute resource (a
subtype of `ComputationalResources.AbstractResource`) that will be used to
accelerate/parallelize the resampling operation.

Although evaluate! is mutating, `mach.model` and `mach.args` are
untouched.

"""
function evaluate!(mach::Machine{<:Supervised};
                   resampling=CV(),
                   measures=nothing, measure=measures, weights=nothing,
                   operation=predict, acceleration=DEFAULT_RESOURCE[],
                   rows=nothing, force=false,
                   check_measure=true, verbosity=1)

    # this method just checks validity of options, preprocess the
    # weights and measures, and dispatches a strategy-specific
    # `evaluate!`

    if resampling isa TrainTestPairs && rows !== nothing
        error("You cannot specify `rows` unless `resampling "*
              "isa MLJ.ResamplingStrategy`. ")
    end

    _weights, _measures =
        _process_weights_measures(weights, measure, mach,
                                  operation, verbosity, check_measure)

    if verbosity >= 0 && weights !== nothing
        unsupported = filter(_measures) do m
            !supports_weights(m)
        end
        if !isempty(unsupported)
            unsupported_as_string = string(unsupported[1])
            unsupported_as_string *=
                reduce(*, [string(", ", m) for m in unsupported[2:end]])
                @warn "Sample weights ignored in evaluations of the following"*
            " measures, as unsupported: \n$unsupported_as_string "
        end
    end

    evaluate!(mach, resampling, _weights, rows, verbosity,
                   _measures, operation, acceleration, force)

end

"""
    evaluate(model, X, y; measure=nothing, options...)
    evaluate(model, X, y, w; measure=nothing, options...)

Evaluate the performance of a supervised model `model` on input data
`X` and target `y`, optionally specifying sample weights `w` for
training, where supported. The same weights are passed to measures
that support sample weights, unless this behaviour is overridden by
explicitly specifying the option `weights=...`.

See the machine version `evaluate!` for the complete list of options.

"""
evaluate(model::Supervised, args...; kwargs...) =
    evaluate!(machine(model, args...); kwargs...)

const AbstractRow = Union{AbstractVector{<:Integer}, Colon}
const TrainTestPair = Tuple{AbstractRow,AbstractRow}
const TrainTestPairs = AbstractVector{<:TrainTestPair}

function _evaluate!(func::Function, res::CPU1, nfolds, verbosity)
    p = Progress(nfolds + 1, dt=0, desc="Evaluating over $nfolds folds: ",
                 barglyphs=BarGlyphs("[=> ]"), barlen=25, color=:yellow)
    verbosity > 0 && next!(p)
    return reduce(vcat, (func(k, p, verbosity) for k in 1:nfolds))
end
function _evaluate!(func::Function, res::CPUProcesses, nfolds, verbosity)
    # TODO: use pmap here ?:
    return @distributed vcat for k in 1:nfolds
        func(k)
    end
end
@static if VERSION >= v"1.3.0-DEV.573"
    function _evaluate!(func::Function, res::CPUThreads, nfolds, verbosity)
        task_vec = [Threads.@spawn func(k) for k in 1:nfolds]
        return fetch.(task_vec)
    end
end

# Evaluation when resampling is not a ResamplingStrategy (core evaluator):
function evaluate!(mach::Machine, resampling, weights, rows, verbosity,
                   measures, operation, acceleration, force)

    # Note: `rows` is ignored here

    resampling isa TrainTestPairs ||
        error("`resampling` must be an "*
              "MLJ.ResamplingStrategy or tuple of pairs "*
              "of the form `(train_rows, test_rows)`")

    X = mach.args[1]
    y = mach.args[2]

    nfolds = length(resampling)

    nmeasures = length(measures)

    function get_measurements(k)
        train, test = resampling[k]
        fit!(mach; rows=train, verbosity=verbosity-1, force=force)
        Xtest = selectrows(X, test)
        ytest = selectrows(y, test)
        if weights == nothing
            wtest = nothing
        else
            wtest = weights[test]
        end
        yhat = operation(mach, Xtest)
        return [value(m, yhat, Xtest, ytest, wtest)
                for m in measures]
    end
    function get_measurements(k, p, verbosity) # p = progress meter
        ret = get_measurements(k)
        verbosity > 0 && next!(p)
        return ret
    end

    measurements_flat = if acceleration isa CPUProcesses
        ## TODO: progress meter for distributed case
        if verbosity > 0
            @info "Distributing cross-validation computation " *
                  "among $(nworkers()) workers."
        end
    end
    measurements_flat =
        _evaluate!(get_measurements, acceleration, nfolds, verbosity)

    # in the following rows=folds, columns=measures:
    measurements_matrix = permutedims(
        reshape(measurements_flat, (nmeasures, nfolds)))

    # measurements for each observation:
    per_observation = map(1:nmeasures) do m
        if reports_each_observation(measures[m])
            [measurements_matrix[:,m]...]
        else
            missing
        end
    end

    # measurements for each fold:
    per_fold = map(1:nmeasures) do m
        if reports_each_observation(measures[m])
            mean.(per_observation[m])
        else
            [measurements_matrix[:,m]...]
        end
    end

    # overall means (one per measure):
    per_measure = mean.(per_fold)

    ret = (measure=measures,
           measurement=per_measure,
           per_fold=per_fold,
           per_observation=per_observation)

    verbosity < 1 || nmeasures < 2 ||
        pretty(selectcols(ret, 1:2), showtypes=false)

    return ret

end

function actual_rows(rows, N, verbosity)
    unspecified_rows = (rows === nothing)
    _rows = unspecified_rows ? (1:N) : rows
    unspecified_rows || @info "Creating subsamples from a subset of all rows. "
    return _rows
end

# Evaluation when resampling is a ResamplingStrategy:
function evaluate!(mach::Machine, resampling::ResamplingStrategy,
                   weights, rows, verbosity, args...)

    y = mach.args[2]
    _rows = actual_rows(rows, length(y), verbosity)

    return evaluate!(mach::Machine,
                     train_test_pairs(resampling, _rows, mach.args...),
                     weights, nothing, verbosity, args...)

end


## RESAMPLER - A MODEL WRAPPER WITH `evaluate` OPERATION

"""
$TYPEDEF

Resampler structure for the `TunedModel` `fit` defined in
`tuning.jl`.

The sample `weights` are passed to the specified performance
measures that support weights for evaluation.

*Important:* If `weights` are left unspecified, then any weight vector
`w` used in constructing the resampler machine, as in
`resampler_machine = machine(resampler, X, y, w)` (which is then used
in *training* the model) will also be used in evaluation.

"""
mutable struct Resampler{S,M<:Supervised} <: Supervised
    model::M
    resampling::S # resampling strategy
    measure
    weights::Union{Nothing,AbstractVector{<:Real}}
    operation
    acceleration::AbstractResource
    check_measure::Bool
end


MLJBase.package_name(::Type{<:Resampler}) = "MLJ"
MLJBase.is_wrapper(::Type{<:Resampler}) = true
MLJBase.supports_weights(::Type{<:Resampler{<:Any,M}}) where M =
    supports_weights(M)

function MLJBase.clean!(resampler::Resampler)
    warning = ""
    if resampler.measure === nothing
        measure = default_measure(resampler.model)
        if measure === nothing
            error("No default measure known for $(resampler.model). "*
                  "You must specify measure=... ")
        else
            warning *= "No `measure` specified. "*
            "Setting `measure=$measure`. "
        end
    end
    return warning
end

function Resampler(; model=ConstantRegressor(), resampling=CV(),
            measure=nothing, weights=nothing, operation=predict,
                   acceleration=DEFAULT_RESOURCE[], check_measure=true)

    resampler = Resampler(model, resampling, measure, weights, operation,
                          acceleration, check_measure)
    message = MLJBase.clean!(resampler)
    isempty(message) || @warn message

    return resampler

end

function MLJBase.fit(resampler::Resampler, verbosity::Int, args...)

    mach = machine(resampler.model, args...)

    weights, measures =
        _process_weights_measures(resampler.weights, resampler.measure,
                                  mach, resampler.operation,
                                  verbosity, resampler.check_measure)

    fitresult = evaluate!(mach, resampler.resampling,
                          weights, nothing, verbosity - 1,
                          measures, resampler.operation,
                          resampler.acceleration, false)

    cache = (mach, deepcopy(resampler.resampling))
    report = NamedTuple()

    return fitresult, cache, report

end

# in special case of holdout, we can reuse the underlying model's
# machine, provided the training_fraction has not changed:
function MLJBase.update(resampler::Resampler{Holdout},
                        verbosity::Int, fitresult, cache, args...)

    old_mach, old_resampling = cache

    if old_resampling.fraction_train == resampler.resampling.fraction_train
        mach = old_mach
    else
        mach = machine(resampler.model, args...)
        cache = (mach, deepcopy(resampler.resampling))
    end

    weights, measures =
        _process_weights_measures(resampler.weights, resampler.measure,
                                  mach, resampler.operation,
                                  verbosity, resampler.check_measure)

    fitresult = evaluate!(mach, resampler.resampling,
                          weights, nothing, verbosity - 1,
                          measures, resampler.operation,
                          resampler.acceleration, false)


    report = NamedTuple

    return fitresult, cache, report

end

MLJBase.input_scitype(::Type{<:Resampler{S,M}}) where {S,M} = MLJBase.input_scitype(M)
MLJBase.target_scitype(::Type{<:Resampler{S,M}}) where {S,M} = MLJBase.target_scitype(M)


## EVALUATE FOR MODEL + DATA

MLJBase.evaluate(model::Resampler, fitresult) = fitresult
