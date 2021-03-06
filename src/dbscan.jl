# DBSCAN Clustering
#
#   References:
#
#       Martin Ester, Hans-peter Kriegel, Jörg S, and Xiaowei Xu
#       A density-based algorithm for discovering clusters
#       in large spatial databases with noise. 1996.
#

using NearestNeighbors


type DbscanResult <: ClusteringResult
    seeds::Vector{Int}          # starting points of clusters, size (k,)
    assignments::Vector{Int}    # assignments, size (n,)
    counts::Vector{Int}         # number of points in each cluster, size (k,)
end


immutable Cluster
  size::Int64
  core_indices::Vector{Int64}
  boundary_indices::Vector{Int64}
end


## main algorithm

function dbscan{T<:Real}(D::DenseMatrix{T}, eps::Real, minpts::Int)
    # check arguments
    n = size(D, 1)
    size(D, 2) == n || error("D must be a square matrix.")
    n >= 2 || error("There must be at least two points.")
    eps > 0 || error("eps must be a positive real value.")
    minpts >= 1 || error("minpts must be a positive integer.")

    # invoke core algorithm
    _dbscan(D, convert(T, eps), minpts, 1:n)
end

function _dbscan{T<:Real}(D::DenseMatrix{T}, eps::T, minpts::Int, visitseq::AbstractVector{Int})
    n = size(D, 1)

    # prepare
    seeds = Int[]
    counts = Int[]
    assignments = zeros(Int, n)
    visited = zeros(Bool, n)
    k = 0

    # main loop
    for p in visitseq
        if assignments[p] == 0 && !visited[p]
            visited[p] = true
            nbs = _dbs_region_query(D, p, eps)
            if length(nbs) >= minpts
                k += 1
                cnt = _dbs_expand_cluster!(D, k, p, nbs, eps, minpts, assignments, visited)
                push!(seeds, p)
                push!(counts, cnt)
            end
        end
    end

    # make output
    return DbscanResult(seeds, assignments, counts)
end

## key steps

function _dbs_region_query{T<:Real}(D::DenseMatrix{T}, p::Int, eps::T)
    n = size(D,1)
    nbs = Int[]
    dists = view(D,:,p)
    for i = 1:n
        @inbounds if dists[i] < eps
            push!(nbs, i)
        end
    end
    return nbs::Vector{Int}
end

function _dbs_expand_cluster!{T<:Real}(D::DenseMatrix{T},           # distance matrix
                                       k::Int,                      # the index of current cluster
                                       p::Int,                      # the index of seeding point
                                       nbs::Vector{Int},            # eps-neighborhood of p
                                       eps::T,                      # radius of neighborhood
                                       minpts::Int,                 # minimum number of neighbors of a density point
                                       assignments::Vector{Int},    # assignment vector
                                       visited::Vector{Bool})       # visited indicators
    assignments[p] = k
    cnt = 1
    while !isempty(nbs)
        q = shift!(nbs)
        if !visited[q]
            visited[q] = true
            qnbs = _dbs_region_query(D, q, eps)
            if length(qnbs) > minpts
                for x in qnbs
                    if assignments[x] == 0
                        push!(nbs, x)
                    end
                end
            end
        end
        if assignments[q] == 0
            assignments[q] = k
            cnt += 1
        end
    end
    return cnt
end



"""
Update the que for expanding the cluster

\_update_exploration_list!( adj_list, exploration_list, visited)

Input:
  adj_list (Vector{Integer}): indices of the neighboring points
  exploration_list (Vector{Integer}): the indices that  will be explored in the future
  visited  (Vector{Bool}): a flag to indicet whether a point has been explored already
"""
function _update_exploration_list!{T <: Integer, U <: Integer}(adj_list::Array{T}, exploration_list::Vector{U}, visited::Vector{Bool})
  for j in adj_list
    visited[j] && continue
    push!(exploration_list, j)
  end
end


"""
Except cluster and updete the clusters list

\_except_cluster!(clusters, core_selection, cluster_selection)

Input:
  clusters (Vector{Cluster}): a list of tyhe accepted clusters
  core_selection (Vector{Bool}): selection of the core points of the cluster
  cluster_selection (Vector{Bool}): selection of the all the cluster points
"""
function _except_cluster!(clusters::Vector{Cluster}, core_selection::Vector{Bool}, cluster_selection::Vector{Bool})
    core_idx = find(core_selection) # index list of the core members
    boundary_idx = find(cluster_selection & ~core_selection) # index list of the boundary members
    push!(clusters, Cluster(sum(cluster_selection), core_idx, boundary_idx))
end


"""
DBSCAN clustering for a large number of points and minimum cluster size

clusters = dbscan(points, radius, min_neighbors, min_cluster_size)

Input:
  points (Real): DxN matrix of N points in D dimensions
  radius (Real) environment radius
  min_neighbors (Interger): minimum number of neightbors to be a core point
  min_cluster_size (Interger): minimum number of points to be a valid cluster

Output:
  Array[Cluster]: an array of clusters with the id, size core indices and boundary indices
"""
function dbscan{T <: Real, N}(points::Array{T, N}, radius::Real, min_neighbors::Integer, min_cluster_size::Integer)
  dim, num_points = size(points)
  num_points <= dim && error("points has $dim rows and $num_points columns, when it must be a D x N matric with D < N")
  0 < radius || error("radius $radius must be a positive real value.")
  1 <= min_neighbors || error("min_neighbors $min_neighbors must be a positive integer.")
  1 <= min_cluster_size || error("min_cluster_size $min_cluster_size must be a positive integer.")
  return  _dbscan(points, radius, min_neighbors, min_cluster_size)
end


function _dbscan(points, radius, min_neighbors, min_cluster_size)
  num_points = size(points, 2)
  clusters = Vector{Cluster}(0)

  visited = zeros(Bool, num_points)
  cluster_selection = zeros(Bool, num_points)
  core_selection = zeros(Bool, num_points)

  to_explore = Vector{Int64}(0)

  kdtree = KDTree(points; leafsize=20)
  for i=1:num_points
    visited[i] && continue
    push!(to_explore, i) # start a new cluster
    core_selection[:] = false
    cluster_selection[:] = false
    cluster_selection[i] = true
    while !isempty(to_explore)
      current_index = shift!(to_explore)
      visited[current_index] && continue
      visited[current_index] = true
      adj_list = inrange(kdtree, points[:, current_index], radius)
      cluster_selection[adj_list] = true # all the neighbors are part of the cluster
      # if a point doesn't have enough neighbours it is not a 'core' point and its neighbours are not added to the to_explore list
      length(adj_list) <= min_neighbors && continue
      core_selection[current_index] = true
      _update_exploration_list!(adj_list, to_explore, visited)
    end
    cluster_size = sum(cluster_selection)
    min_cluster_size <= cluster_size && _except_cluster!(clusters, cluster_selection, core_selection)
  end
  return clusters
end
