module GraphSAGE
    using Statistics;
    using StatsBase: sample;
    using LightGraphs;
    using Flux;

    export graph_encoder;

    struct AGG{F}
        S::String;
        L::F;
    end

    function AGG(S::String, dim_h::Int, σ=relu)
        """"
        dim_h: dimension of vertice embedding
        """

        @assert S in ["SAGE_GCN", "SAGE_Mean", "SAGE_Max", "SAGE_Sum", "SAGE_MaxPooling"];

        if S in ["SAGE_MaxPooling"]
            return AGG(S, Dense(dim_h, dim_h, σ));
        else
            return AGG(S, nothing);
        end
    end

    function (c::AGG)(h::Vector)
        S, L = c.S, c.L;

        H = Flux.hcat(h...);

        if S in ["SAGE_GCN", "SAGE_Mean"]
            return Flux.mean(H, dims=2)[:];
        elseif S in ["SAGE_Max"]
            return Flux.maximum(H, dims=2)[:];
        elseif S in ["SAGE_Sum"]
            return Flux.sum(H, dims=2)[:];
        elseif S in ["SAGE_MaxPooling"]
            return Flux.maximum(L(H), dims=2)[:];
        end
    end

    Flux.@functor AGG;



    # sampler & aggregator
    struct SAGE{F}
        T::F;
        k::Int;
        A::AGG;
        z::AbstractVector; # default value (when vertex has no edge)
    end

    function SAGE(T::F, k::Int, S::String, dim_h::Int, σ=relu) where {F}
        return SAGE(T, k, AGG(S, dim_h, σ), zeros(Float32, dim_h));
    end

    function (c::SAGE)(G::AbstractGraph, node_list::Vector{Int}, node_features::Function)
        T, k, A, z = c.T, c.k, c.A, c.z;

        sampled_nbrs_list = Vector{Vector{Int}}();
        for u in node_list
            nbrs = inneighbors(G, u);
            push!(sampled_nbrs_list, length(nbrs) > k ? sample(nbrs, k, replace=false) : nbrs);
        end

        # compute hidden vector of unique neighbors
        unique_nodes = union(node_list, sampled_nbrs_list...);
        u2i = Dict{Int,Int}(u=>i for (i,u) in enumerate(unique_nodes));

        # if this SAGE is not a leaf, then call the child Transformer to get node representation at previous layer
        if T != nothing
            h0 = T(G, unique_nodes, node_features);
        else
            h0 = [f32(node_features(u)) for u in unique_nodes];
        end

        # each vector can be decomposed as [h(v)*, h(u)], where * means 'aggregated across v'
        hh = Vector{AbstractVector}();
        for (u, sampled_nbrs) in zip(node_list, sampled_nbrs_list)
            if A.S in ["SAGE_GCN"]
                ht = A(vcat([h0[u2i[u]]], [h0[u2i[v]] for v in sampled_nbrs]));
            elseif A.S in ["SAGE_Mean", "SAGE_Max", "SAGE_Sum", "SAGE_MaxPooling"]
                hn = length(sampled_nbrs) != 0 ? A([h0[u2i[v]] for v in sampled_nbrs]) : z;
                ht = vcat(h0[u2i[u]], hn)
            end
            push!(hh, ht);
        end

        return hh;
    end

    Flux.@functor SAGE;

    # transformer
    struct Transformer{F}
        S::SAGE;
        L::F;
    end

    function Transformer(S::SAGE, dim_h0::Int, dim_h1::Int, σ=relu)
        if S.A.S in ["SAGE_GCN"]
            L = Dense(dim_h0, dim_h1, σ);
        elseif S.A.S in ["SAGE_Mean", "SAGE_Max", "SAGE_Sum", "SAGE_MaxPooling"]
            L = Dense(dim_h0*2, dim_h1, σ);
        end

        return Transformer(S, L);
    end

    function (c::Transformer)(G::AbstractGraph, node_list::Vector{Int}, node_features::Function)
        S, L = c.S, c.L;

        h1 = L.(S(G, node_list, node_features));

        return h1;
    end

    Flux.@functor Transformer;



    # graph encoder
    function graph_encoder(dim_in::Int, dim_out::Int, dim_h::Int, layers::Vector{String};
                           ks::Vector{Int}=repeat([typemax(Int)], length(layers)), σ=relu)
    """
    Args:
       dim_in: node feature dimension
      dim_out: embedding dimension
        dim_h: hidden dimension
       layers: each is a convolution layer of a certain convolution type
           ks: max number of sampled neighbors to pull

    Returns:
         tsfm: a model that takes 1) graph topology 2) vertex features 3) vertices to be encoded 
               as inputs and gives vertex embeddings as output
    """

        @assert length(layers) > 0;
        @assert length(layers) == length(ks);

        sage = SAGE(nothing, ks[1], layers[1], dim_in, σ);
        if length(layers) == 1
            # single layer, directly output
            tsfm = Transformer(sage, dim_in, dim_out, σ);
        else
            # multiple layer, first encode to hidden
            tsfm = Transformer(sage, dim_in, dim_h, σ);

            # the inner layers, hidden to hidden
            for i in 2:length(layers)-1
                sage = SAGE(tsfm, ks[i], layers[i], dim_h, σ);
                tsfm = Transformer(sage, dim_h, dim_h, σ);
            end

            sage = SAGE(tsfm, ks[end], layers[end], dim_h, σ);
            tsfm = Transformer(sage, dim_h, dim_out, σ);
        end

        return tsfm;
    end
end
