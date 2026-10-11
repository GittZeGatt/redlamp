import Foundation
import RedlampDocument

extension ColumnStore {
    /// The soft-frame verdicts of the photos of `rows` with a capture time, in moments as `setting` finds them among
    /// them: `stacks` are the library's (bursts and pairs), `sharpness` its measurements by photo ID. A photo whose
    /// pair's top photo is among `rows` is judged with it; one whose top isn't, a JPEG filtered apart from its raw,
    /// on its own.
    func softFrames(
        of rows: RowBits, stacks: Stacks, sharpness: [Int64: PhotoSharpness], mode: SoftFrames.Mode,
        setting: MomentSetting,
    ) -> SoftFrames {
        let ordered = datedRows(of: rows)
        var frames: [SoftFrames.Frame] = []
        var times = ContiguousArray<Int64>()
        var burstOfFrame: [Int32] = []
        frames.reserveCapacity(ordered.count)
        times.reserveCapacity(ordered.count)
        burstOfFrame.reserveCapacity(ordered.count)
        let pick = UInt16(PhotoRecord.code(for: .pick))
        let reject = UInt16(PhotoRecord.code(for: .reject))
        let pairCount = stacks.pairOf.count
        captured.withUnsafeBufferPointer { captured in
            packed.withUnsafeBufferPointer { packed in
                customLabels.withUnsafeBufferPointer { customLabels in
                    func decide(_ row: Int, _ decision: inout SoftFrames.Decision) {
                        let value = packed[row]
                        decision.picked = decision.picked || Packed.flag(value) == pick
                        decision.rejected = decision.rejected || Packed.flag(value) == reject
                        decision.rated = decision.rated || Packed.rating(value) > 0
                        decision.labelled = decision.labelled || Packed.label(value) != 0 || customLabels[row] != 0
                    }
                    for row in ordered {
                        let id = ids[Int(row)]
                        var photos = [id]
                        var decision = SoftFrames.Decision()
                        decide(Int(row), &decision)
                        let pair = id >= 0 && id < pairCount ? Int(stacks.pairOf[Int(id)]) : -1
                        if pair >= 0 {
                            let members = stacks.members(of: pair)
                            if let top = members.first, top != id, let topRow = self.row(of: top),
                               rows.contains(topRow) {
                                continue
                            }
                            if members.first == id {
                                for member in members.dropFirst() {
                                    guard let memberRow = self.row(of: member),
                                          rows.contains(memberRow) else { continue }
                                    photos.append(member)
                                    decide(memberRow, &decision)
                                }
                            }
                        }
                        let group = id >= 0 && id < stacks.groupOf.count ? stacks.groupOf[Int(id)] : -1
                        let burst = group >= 0 && stacks.kinds[Int(group)] == .burst ? group : -1
                        let measured = photos.lazy.compactMap { sharpness[$0] }.first
                        frames.append(SoftFrames.Frame(photos: photos, sharpness: measured, decision: decision))
                        times.append(captured[Int(row)])
                        burstOfFrame.append(burst)
                    }
                }
            }
        }
        var bursts: [Int32: [Int]] = [:]
        for (place, burst) in burstOfFrame.enumerated() where burst >= 0 {
            bursts[burst, default: []].append(place)
        }
        var moments: [[Int]] = []
        if mode != .runsOnly {
            let starts = times.withUnsafeBufferPointer { MomentFinder.starts($0, setting: setting) }
            var first = 0
            for start in starts + [Int32(frames.count)] {
                if Int(start) > first {
                    moments.append(Array(first ..< Int(start)))
                }
                first = Int(start)
            }
        }
        let ordering = bursts.keys.sorted()
        return SoftFrames.judge(frames, bursts: ordering.compactMap { bursts[$0] }, moments: moments, mode: mode)
    }

    /// The rows of `rows` with a capture time, in capture order.
    private func datedRows(of rows: RowBits) -> ContiguousArray<Int32> {
        var dated = ContiguousArray<Int32>()
        let total = rows.count
        dated.reserveCapacity(total)
        captured.withUnsafeBufferPointer { captured in
            if total >= count / 8 {
                byCaptured.withUnsafeBufferPointer { order in
                    for row in order where rows.contains(Int(row)) && captured[Int(row)] != .min {
                        dated.append(row)
                    }
                }
            } else {
                rows.forEach { row in
                    if captured[row] != .min {
                        dated.append(Int32(row))
                    }
                    return true
                }
                dated.sort { captured[Int($0)] != captured[Int($1)] ? captured[Int($0)] < captured[Int($1)] : $0 < $1 }
            }
        }
        return dated
    }
}
