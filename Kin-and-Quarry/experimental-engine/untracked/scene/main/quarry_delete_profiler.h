#pragma once

#ifdef DEBUG_ENABLED

#include <stdint.h>

namespace QuarryDelete {

enum Site {
	DESTRUCTOR,
	PREDELETE,
	REMOVE_CHILD,
	EXIT_TREE,
	EXIT_SCRIPT_AND_SIGNAL,
	EXIT_NOTIFICATION,
	PROCESS_GROUP_UNREGISTER,
	SCENE_GROUP_UNREGISTER,
	EXIT_NODE_REMOVED_SIGNAL,
	EXIT_TREE_CHANGED_SIGNAL,
	AFTER_EXIT_TREE,
	DESTROY_CHILD,
	DESTROY_CHILD_SPRITE3D,
	DESTROY_CHILD_ANIMATEDSPRITE3D,
	DESTROY_CHILD_GPUPARTICLES3D,
	DESTROY_CHILD_CPUPARTICLES3D,
	DESTROY_CHILD_ANIMATIONPLAYER,
	DESTROY_CHILD_ANIMATIONTREE,
	DESTROY_CHILD_TIMER,
	DESTROY_CHILD_COLLISIONSHAPE3D,
	DESTROY_CHILD_AREA3D,
	DESTROY_CHILD_MESHINSTANCE3D,
	DESTROY_CHILD_OMNILIGHT3D,
	DESTROY_CHILD_AUDIOSTREAMPLAYER3D,
	DESTROY_CHILD_AUDIOSTREAMPLAYER,
	DESTROY_CHILD_NODE3D,
	RENDER_FREE,
	CULL_DIRTY_DRAIN,
	RD_DEPS,
	RD_FREE,
	OBJECT_PREDELETE,
	OBJECT_DESTRUCTOR,
	SITE_COUNT,
};

struct Root {
	uint64_t elapsed[SITE_COUNT]{};
	uint64_t visits[SITE_COUNT]{};
	Site active = DESTRUCTOR;
	uint64_t last = 0;
	void account(uint64_t p_now);
};

extern thread_local Root *current;

class Scope {
	Root *root = current;
	Site previous = DESTRUCTOR;
	void transition(Site p_site, bool p_count);

public:
	explicit Scope(Site p_site) {
		if (root) {
			previous = root->active;
			transition(p_site, true);
		}
	}
	~Scope() {
		if (root) {
			transition(previous, false);
		}
	}
};

} // namespace QuarryDelete

#define QUARRY_DELETE_SCOPE(m_site) QuarryDelete::Scope quarry_delete_scope_##m_site(QuarryDelete::m_site)
#else
#define QUARRY_DELETE_SCOPE(m_site) ((void)0)
#endif
