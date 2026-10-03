import Foundation

/// Decides which high-score jobs are new to the user (for notifications / menu bar badge).
public enum NewJobDetector {
    /// Jobs with status "neu", score ≥ threshold, whose id is not in `seen`; best first.
    public static func newJobs(in jobs: [JobSummary], seen: Set<Int>, threshold: Int) -> [JobSummary] {
        highScoreUntriaged(jobs, threshold: threshold).filter { !seen.contains($0.id) }
    }

    /// Untriaged ("neu") jobs above the threshold, best first.
    public static func highScoreUntriaged(_ jobs: [JobSummary], threshold: Int) -> [JobSummary] {
        jobs.filter { $0.status == .neu && $0.score >= threshold }
            .sorted { ($0.score, $0.fetchedAt) > ($1.score, $1.fetchedAt) }
    }

    /// Keeps the persisted "seen" set bounded: retains ids still present plus the newest extras.
    public static func pruned(_ seen: Set<Int>, current: [JobSummary], keep: Int = 2000) -> Set<Int> {
        if seen.count <= keep { return seen }
        let currentIDs = Set(current.map(\.id))
        let still = seen.intersection(currentIDs)
        let rest = seen.subtracting(currentIDs).sorted(by: >).prefix(max(0, keep - still.count))
        return still.union(rest)
    }
}
