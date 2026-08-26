using System;
using System.Collections.Generic;
using Maths.Geometry;
using Synthetic;

namespace Synthetic.Manifolds;

/// <summary>
/// Generates a hierarchical cluster tree directly in the Poincaré ball.
/// Leaf clusters are arranged recursively so broad branches separate near
/// the core and finer branches peel outward toward the boundary. Child
/// centers are placed at a fixed geodesic step and leaves scattered in the
/// tangent space, both realized through the real
/// <see cref="PoincareBallManifold"/> exponential map — the hyperbolic volume
/// growth supplies the separation a Euclidean construction would fake with a
/// growing step size.
/// Reference: hierarchical Poincaré ball cluster benchmark.
/// </summary>
public static class HyperbolicHierarchy
{
    public static SyntheticDataset Generate(
        int nPoints = 6000,                  // bumped from 1200 → plausible-data scale
        int hierarchyDepth = 3,
        int branchesPerNode = 3,
        int basePointsPerLeaf = 250,         // bumped from 50 → matches leaf-count × N target
        int dimensions = 2,
        double baseSeparation = 1.0,         // geodesic step per level (constant; hyperbolic room handles spread)
        double radiusDecay = 0.65,
        double noiseScale = 0.22,
        int seed = 42)
    {
        if (nPoints < 1) throw new ArgumentException("nPoints must be positive.");
        if (hierarchyDepth < 1) throw new ArgumentException("hierarchyDepth must be >= 1.");
        if (branchesPerNode < 2) throw new ArgumentException("branchesPerNode must be >= 2.");
        if (dimensions < 2) throw new ArgumentException("HyperbolicHierarchy requires dimensions >= 2.");
        if (baseSeparation <= 0.0) throw new ArgumentException("baseSeparation must be positive.");
        if (radiusDecay <= 0.0 || radiusDecay >= 1.0) throw new ArgumentException("radiusDecay must be in (0, 1).");
        if (noiseScale < 0.0) throw new ArgumentException("noiseScale must be non-negative.");

        var rng = new Random(seed);
        var manifold = new PoincareBallManifold(dimensions);
        var points = new List<double[]>(nPoints);
        var leafLabels = new List<int>(nPoints);
        var labelsByLevel = new List<int>[hierarchyDepth];
        for (int level = 0; level < hierarchyDepth; level++)
            labelsByLevel[level] = new List<int>(nPoints);

        var nextLabelByLevel = new int[hierarchyDepth];
        int nextLeafLabel = 0;

        GenerateRecursive(
            manifold: manifold,
            center: new double[dimensions],
            level: 0,
            remainingPoints: nPoints,
            hierarchyDepth: hierarchyDepth,
            branchesPerNode: branchesPerNode,
            basePointsPerLeaf: basePointsPerLeaf,
            baseSeparation: baseSeparation,
            radiusDecay: radiusDecay,
            noiseScale: noiseScale,
            rng: rng,
            points: points,
            leafLabels: leafLabels,
            labelsByLevel: labelsByLevel,
            pathLabels: Array.Empty<int>(),
            nextLabelByLevel: nextLabelByLevel,
            nextLeafLabel: ref nextLeafLabel);

        while (points.Count > nPoints)
        {
            points.RemoveAt(points.Count - 1);
            leafLabels.RemoveAt(leafLabels.Count - 1);
            for (int level = 0; level < hierarchyDepth; level++)
                labelsByLevel[level].RemoveAt(labelsByLevel[level].Count - 1);
        }

        while (points.Count < nPoints)
        {
            points.Add(new double[dimensions]);
            leafLabels.Add(0);
            for (int level = 0; level < hierarchyDepth; level++)
                labelsByLevel[level].Add(0);
        }

        var levelArrays = new int[hierarchyDepth][];
        for (int level = 0; level < hierarchyDepth; level++)
            levelArrays[level] = labelsByLevel[level].ToArray();

        return new SyntheticDataset
        {
            Features = points.ToArray(),
            Labels = leafLabels.ToArray(),
            ClusterCount = Math.Max(nextLeafLabel, 1),
            LabelsByLevel = levelArrays,
            Parameters = new Dictionary<string, object>
            {
                ["generator"] = "HyperbolicHierarchy",
                ["nPoints"] = nPoints,
                ["hierarchyDepth"] = hierarchyDepth,
                ["branchesPerNode"] = branchesPerNode,
                ["basePointsPerLeaf"] = basePointsPerLeaf,
                ["dimensions"] = dimensions,
                ["baseSeparation"] = baseSeparation,
                ["radiusDecay"] = radiusDecay,
                ["noiseScale"] = noiseScale,
                ["seed"] = seed,
                ["model"] = "Poincare ball hierarchy",
            },
            Metadata = new SyntheticDatasetMeta(
                GeneratorName: nameof(HyperbolicHierarchy),
                GeometryClass: "Manifold",
                TopologyTag: "hierarchical",
                HierarchyTag: "natural",
                GTNumClusters: Math.Max(nextLeafLabel, 1),
                AmbientDimensionality: dimensions,
                LiteratureReference: "hierarchical Poincaré ball cluster benchmark",
                SuggestedMetric: "poincare")
        };
    }

    private static void GenerateRecursive(
        PoincareBallManifold manifold,
        double[] center,
        int level,
        int remainingPoints,
        int hierarchyDepth,
        int branchesPerNode,
        int basePointsPerLeaf,
        double baseSeparation,
        double radiusDecay,
        double noiseScale,
        Random rng,
        List<double[]> points,
        List<int> leafLabels,
        List<int>[] labelsByLevel,
        int[] pathLabels,
        int[] nextLabelByLevel,
        ref int nextLeafLabel)
    {
        bool stopAtLeaf = level >= hierarchyDepth || remainingPoints <= basePointsPerLeaf;
        if (stopAtLeaf)
        {
            int leafLabel = nextLeafLabel++;
            double leafRadius = 0.8 * Math.Pow(radiusDecay, Math.Max(0, level));
            for (int i = 0; i < remainingPoints; i++)
            {
                double[] tangent = new double[center.Length];
                for (int d = 0; d < center.Length; d++)
                    tangent[d] = leafRadius * SyntheticData.SampleStandardNormal(rng);

                double[] sample = HyperbolicExpMap(manifold, center, tangent, noiseScale, rng);
                points.Add(sample);
                leafLabels.Add(leafLabel);

                int fallback = pathLabels.Length > 0 ? pathLabels[^1] : 0;
                for (int depth = 0; depth < labelsByLevel.Length; depth++)
                    labelsByLevel[depth].Add(depth < pathLabels.Length ? pathLabels[depth] : fallback);
            }

            return;
        }

        int baseChildPoints = remainingPoints / branchesPerNode;
        int remainder = remainingPoints % branchesPerNode;

        for (int branch = 0; branch < branchesPerNode; branch++)
        {
            int childPoints = baseChildPoints + (branch < remainder ? 1 : 0);
            if (childPoints <= 0)
                continue;

            int childLabel = nextLabelByLevel[level]++;
            var childPath = new int[pathLabels.Length + 1];
            Array.Copy(pathLabels, childPath, pathLabels.Length);
            childPath[^1] = childLabel;

            double[] direction = RandomDirection(center.Length, rng);
            double[] childCenter = HyperbolicTranslate(manifold, center, direction, baseSeparation);

            GenerateRecursive(
                manifold,
                childCenter,
                level + 1,
                childPoints,
                hierarchyDepth,
                branchesPerNode,
                basePointsPerLeaf,
                baseSeparation,
                radiusDecay,
                noiseScale,
                rng,
                points,
                leafLabels,
                labelsByLevel,
                childPath,
                nextLabelByLevel,
                ref nextLeafLabel);
        }
    }

    /// <summary>
    /// Scatter a leaf point: <c>exp_center(tangent + noise)</c> on the ball. The
    /// conformal factor of the real exp map attenuates the ambient displacement
    /// near the boundary — no manual attenuation needed.
    /// </summary>
    private static double[] HyperbolicExpMap(
        PoincareBallManifold manifold, double[] center, double[] tangent, double noiseScale, Random rng)
    {
        var v = new double[center.Length];
        for (int i = 0; i < v.Length; i++)
            v[i] = tangent[i] + noiseScale * SyntheticData.SampleStandardNormal(rng);

        var dst = new double[center.Length];
        manifold.ExpMap(center, v, dst);
        return dst;
    }

    /// <summary>
    /// Place a child center at geodesic distance <paramref name="distance"/> from
    /// <paramref name="from"/> along <paramref name="direction"/>. The unit
    /// tangent's Riemannian norm is the conformal factor λ_from, so a tangent of
    /// Euclidean length <c>distance / λ_from</c> exp-maps to exactly that geodesic
    /// radius.
    /// </summary>
    private static double[] HyperbolicTranslate(
        PoincareBallManifold manifold, double[] from, double[] direction, double distance)
    {
        double[] dir = NormalizeDirection(direction);
        double lambda = manifold.Norm(from, dir);          // λ_from · ‖dir‖ = λ_from
        double scale = lambda > 1e-12 ? distance / lambda : distance;

        var v = new double[from.Length];
        for (int i = 0; i < v.Length; i++)
            v[i] = dir[i] * scale;

        var dst = new double[from.Length];
        manifold.ExpMap(from, v, dst);
        return dst;
    }

    private static double[] RandomDirection(int dim, Random rng)
    {
        var direction = new double[dim];
        for (int i = 0; i < dim; i++)
            direction[i] = SyntheticData.SampleStandardNormal(rng);
        return NormalizeDirection(direction);
    }

    private static double[] NormalizeDirection(double[] vector)
    {
        double norm = EuclideanNorm(vector);
        if (norm < 1e-12)
            return vector;

        var result = new double[vector.Length];
        for (int i = 0; i < vector.Length; i++)
            result[i] = vector[i] / norm;
        return result;
    }

    private static double EuclideanNorm(double[] vector)
    {
        double sumSq = 0.0;
        for (int i = 0; i < vector.Length; i++)
            sumSq += vector[i] * vector[i];
        return Math.Sqrt(sumSq);
    }
}
