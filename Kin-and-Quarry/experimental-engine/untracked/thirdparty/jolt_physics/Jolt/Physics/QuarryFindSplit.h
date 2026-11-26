#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <optional>

// Private diagnostic for the vendored 4.5.1 Jolt. Ordinary runs never arm it.
namespace QuarryFindSplit {

using Count = std::uint64_t;

#define QUARRY_SPLIT_FIELDS(F) \
	F(jobs) F(job_ns) F(broad_batches) F(active_bodies) F(candidate_pairs) \
	F(inline_pairs) F(broad_ns) F(inline_pair_ns) F(pairs) F(pair_ns) \
	F(sensor_pairs) F(cache_bypass) F(cache_lookups) F(cache_hits) F(cache_misses) \
	F(cache_missing_record) F(cache_position_reject) F(cache_rotation_reject) \
	F(cache_zero_manifolds) F(cache_write_full) F(cache_hit_ns) F(cache_miss_ns) \
	F(new_body_pairs) F(new_body_pair_full) F(insert_ns) F(narrow_pairs) F(narrow_ns) \
	F(shape_ns) F(sensor_shape_ns)

struct Totals {
#define QUARRY_DECLARE(name) Count name = 0;
	QUARRY_SPLIT_FIELDS(QUARRY_DECLARE)
#undef QUARRY_DECLARE

	void add(const Totals &other) {
#define QUARRY_ADD(name) name += other.name;
		QUARRY_SPLIT_FIELDS(QUARRY_ADD)
#undef QUARRY_ADD
	}
};

#undef QUARRY_SPLIT_FIELDS

inline std::atomic<unsigned> mode{0};
inline std::mutex pending_lock;
inline Totals pending;
inline thread_local Totals *current = nullptr;
inline thread_local bool clock_current = false;

inline Count now_ns() {
	return static_cast<Count>(std::chrono::duration_cast<std::chrono::nanoseconds>(
		std::chrono::steady_clock::now().time_since_epoch()).count());
}

inline void set_enabled(bool value, bool timed = true) {
	mode.store(value ? (timed ? 2 : 1) : 0, std::memory_order_relaxed);
}

inline Totals take_completed() {
	std::lock_guard<std::mutex> lock(pending_lock);
	Totals accumulated = pending;
	pending = {};
	return accumulated;
}

class Scope {
	Count *counter;
	Count started;
public:
	explicit Scope(Count *target) : counter(target), started(target ? now_ns() : 0) {}
	~Scope() {
		if (counter) {
			*counter += now_ns() - started;
		}
	}
	Scope(const Scope &) = delete;
	Scope &operator=(const Scope &) = delete;
};

inline Count *field(Count Totals::*slot) {
	return clock_current ? &(current->*slot) : nullptr;
}

inline void incr(Count Totals::*slot, Count amount = 1) {
	if (current) {
		(current->*slot) += amount;
	}
}

class Job {
	std::optional<Totals> totals;
	Totals *previous;
	bool previous_clock;
	Count started;
public:
	Job() : previous(current), previous_clock(clock_current), started(0) {
		const unsigned selected = mode.load(std::memory_order_relaxed);
		if (selected) {
			totals.emplace();
			totals->jobs = 1;
			current = &*totals;
			clock_current = selected == 2;
			if (clock_current) {
				started = now_ns();
			}
		}
	}
	~Job() {
		if (totals.has_value()) {
			if (clock_current) {
				totals->job_ns = now_ns() - started;
			}
			current = previous;
			clock_current = previous_clock;
			std::lock_guard<std::mutex> lock(pending_lock);
			pending.add(*totals);
		}
	}
	Job(const Job &) = delete;
	Job &operator=(const Job &) = delete;
};

inline Count subtract(Count inclusive, Count nested) {
	return inclusive >= nested ? inclusive - nested : 0;
}

} // namespace QuarryFindSplit
