using System.Collections.Generic;
using JacRed.Infrastructure.Indexers;
using JacRed.Models.Api;
using Xunit;

namespace JacRed.Tests.Indexers;

public class IndexerResultFiltersTests
{
    static Result Item(int seeders, int peers) => new Result { Seeders = seeders, Peers = peers };

    [Fact]
    public void FilterBySeedPeer_ZeroThreshold_KeepsAll()
    {
        var items = new List<Result> { Item(0, 0), Item(1, 2) };
        Assert.Equal(2, IndexerResultFilters.FilterBySeedPeer(items, 0).Count);
    }

    [Theory]
    [InlineData(0, 0, 5, false)]
    [InlineData(3, 2, 5, true)]
    [InlineData(10, 0, 5, true)]
    [InlineData(2, 2, 5, false)]
    public void FilterBySeedPeer_Threshold_FiltersBySum(int seeders, int peers, int threshold, bool keep)
    {
        var items = new List<Result> { Item(seeders, peers) };
        var filtered = IndexerResultFilters.FilterBySeedPeer(items, threshold);
        Assert.Equal(keep ? 1 : 0, filtered.Count);
    }

    [Fact]
    public void FilterBySeedPeer_KeepsAllAboveThreshold()
    {
        var items = new List<Result> { Item(4, 1), Item(0, 5), Item(2, 0) };
        var filtered = IndexerResultFilters.FilterBySeedPeer(items, 5);
        Assert.Equal(2, filtered.Count);
        Assert.Contains(filtered, r => r.Seeders == 4 && r.Peers == 1);
        Assert.Contains(filtered, r => r.Seeders == 0 && r.Peers == 5);
    }
}
