import numpy as np

cimport numpy as np
cimport libc.stdlib as stdlib
cimport cython

key_index_2d = [0, 1, 3, 2]

cpdef np.uint64_t hilbert_key_2d(np.uint32_t x, np.uint32_t y, int order):

    cdef np.uint64_t key = 0
    cdef int i, xbit, ybit
    for i in range(order-1, -1, -1):

        xbit = 1 if x & (1 << i) else 0
        ybit = 1 if y & (1 << i) else 0

        if   xbit == 0 and ybit == 0: x, y = y, x
        elif xbit == 1 and ybit == 0: x, y = ~y, ~x

        key = (key << 2) + key_index_2d[(xbit << 1) + ybit]

    return key


cdef struct Oct:

    np.uint64_t sfc_key      # space filling curve key for oct
    np.uint32_t level        # level of octree

    np.uint64_t sfc_start_key         # first key in space filling curve cut
    np.uint64_t number_sfc_keys       # total number of possible space filling keys in this oct

    np.int64_t particle_index_start   # index of first particle in space filling curve cut
    np.uint64_t number_particles      # number of particles in cut

    int leaf                 # is this oct a leaf

    np.float64_t box_length  # side length of oct
    np.float64_t center[2]   # center of coordinates of oct

    Oct* parent              # parent of oct
    Oct* children            # children nodes, 4 of them
    int  children_index[4]   # index to point to the right child


cdef class Octree:

    cdef readonly np.ndarray sorted_particle_keys  # hilbert keys of the particles in key order
    cdef readonly int max_leaf_particles           # criteria to subdivide a oct 
    cdef readonly int order                        # number of bits per dimension

    cdef Oct* root
    cdef np.uint32_t xmin, xmax, ymin, ymax

    def __init__(self, sorted_particle_keys, max_leaf_particles, order):

        self.sorted_particle_keys = np.ascontiguousarray(sorted_particle_keys, dtype=np.int64)
        self.order = order

        self.xmin = self.ymin = 0
        self.xmax = self.ymax = 2**(order)
        self.max_leaf_particles = max_leaf_particles

        # build root
        self.root = <Oct*>stdlib.malloc(sizeof(Oct))
        if self.root == <Oct*> NULL:
            raise MemoryError

        # create root node which holds all hilbert possible keys in a
        # grid of 2^order resolution per dimension
        self.root.children = NULL
        self.root.sfc_start_key = 0
        self.root.number_sfc_keys = 2**(2*order)
        self.root.particle_index_start = 0
        self.root.number_particles = sorted_particle_keys.shape[0]
        self.root.level = 0
        self.root.leaf = 1
        self.root.box_length = 2**(order)

        # the center of the root is the center of the grid of hilbert keys
        cdef int i
        for i in range(2):
            self.root.center[i] = 0.5*2**(order)

        # build octree recursively
        self.build_tree()


    cdef void build_tree(self):
        self.fill_particles_in_oct(self.root)


    cdef void fill_particles_in_oct(self, Oct* o):

        # create oct children
        o.children = <Oct*>stdlib.malloc(sizeof(Oct)*4)
        if o.children == <Oct*> NULL:
            raise MemoryError

        # pass parent data to children 
        cdef int i, j
        for i in range(4):

            if o.number_sfc_keys < 4:
                raise RuntimeError("Not enough hilbert keys to be split")

            o.children[i].parent = o
            o.children[i].leaf = 1
            o.children[i].level = o.level + 1

            # each child has a cut of hilbert keys from parent
            o.children[i].number_sfc_keys = o.number_sfc_keys/4
            o.children[i].sfc_start_key   = o.sfc_start_key + i*o.number_sfc_keys/4

            o.children[i].particle_index_start = -1
            o.children[i].number_particles = 0

            o.children[i].box_length = o.box_length/2.0
            o.children[i].children = NULL


        # create children center coordinates by shifting parent coordinates by 
        # half box length in each dimension
        cdef  np.uint64_t key
        cdef int child_oct_index
        for i in range(2):
            for j in range(2):

                # compute hilbert key for each child
                key = hilbert_key_2d( <np.uint32_t> (o.center[0] + (2*i-1)*o.box_length/4.0),
                        <np.uint32_t> (o.center[1] + (2*j-1)*o.box_length/4.0), self.order)

                # find which oct this key belongs to it and store the key
                # center coordinates
                child_oct_index = (key - o.sfc_start_key)/(o.number_sfc_keys/4)
                o.children[child_oct_index].sfc_key = key
                o.children[child_oct_index].center[0] = o.center[0] + (2*i-1)*o.box_length/4.0
                o.children[child_oct_index].center[1] = o.center[1] + (2*j-1)*o.box_length/4.0

                # the children are in hilbert order, this mapping allows to grab children
                # in bottom-left, upper-left, bottom-right, upper-right order
                o.children_index[(i<<1) + j] = child_oct_index


        # loop over parent particles and assign them to proper child
        for i in range(o.particle_index_start, o.particle_index_start + o.number_particles):

            # which oct does this particle belong to
            child_oct_index = (self.sorted_particle_keys[i] - o.sfc_start_key)/(o.number_sfc_keys/4)

            # if child node is empty then this is the first particle in the cut
            if o.children[child_oct_index].number_particles == 0:
                o.children[child_oct_index].particle_index_start = i

            # update the number of particles for child
            o.children[child_oct_index].number_particles += 1


        # parent is no longer a leaf
        o.leaf = 0

        # if child has more particles then the maximum allowed, then subdivide 
        for i in range(4):
            if o.children[i].number_particles > self.max_leaf_particles:
                self.fill_particles_in_oct(&o.children[i])


    def find_oct(self, np.uint64_t key):

        cdef Oct* o = self.find_oct_by_key(key)
        return [o.center[0], o.center[1], o.box_length,
            o.level, o.particle_index_start, o.number_particles]


    cdef Oct* find_oct_by_key(self, np.uint64_t key):

        cdef Oct* candidate = self.root
        cdef int child_oct_index

        while candidate.leaf != 1:
            child_oct_index = (key - candidate.sfc_start_key)/(candidate.number_sfc_keys/4)
            candidate = &candidate.children[child_oct_index]

        return candidate


    cdef Oct* find_oct_by_key_level(self, np.uint64_t key, np.uint32_t level):

        cdef Oct* candidate = self.root
        cdef int child_oct_index

        while candidate.level < level and candidate.leaf != 1:
            child_oct_index = (key - candidate.sfc_start_key)/(candidate.number_sfc_keys/4)
            candidate = &candidate.children[child_oct_index]

        return candidate


    cdef void subneighbor_find(self, list oct_list, Oct* candidate, int i, int j):

        if i == j == 1: return

        cdef Oct* child_cand
        cdef np.int64_t num_loop[2], index[2], off[2][2], ii, ij

        index[0] = i
        index[1] = j

        # num_steps and walk?
        for ii in range(2):

            # no offset 
            if index[ii] == 1:
                num_loop[ii] = 2
                off[ii][0] = 0
                off[ii][1] = 1

            # left offset
            elif index[ii] == 0:
                num_loop[ii] = 1
                off[ii][0] = 1

            # right offset
            elif index[ii] == 2:
                num_loop[ii] = 1
                off[ii][0] = 0

        for ii in range(num_loop[0]):
            for ij in range(num_loop[1]):

                child_index = (off[0][ii] << 1) + off[1][ij]
                child_cand = &candidate.children[candidate.children_index[child_index]]

                if child_cand.children != NULL:
                    self.subneighbor_find(oct_list, child_cand, i, j)
                else:
                    oct_list.append([child_cand.center[0], child_cand.center[1], child_cand.box_length,\
                            child_cand.level, child_cand.particle_index_start, child_cand.number_particles])


    def oct_neighbor_search(self, np.uint64_t key):

        cdef Oct *o, *neighbor
        cdef np.uint64_t oct_key, neighbor_oct_key
        cdef np.int64_t x, y
        cdef list oct_list = []
        cdef int i, j

        cdef set node_set = set()

        # find the oct leaf that the search particle lives in
        o = self.find_oct_by_key(key)

        # find neighbor octs by shifting leaf oct key by half box length
        for i in range(3):
            for j in range(3):

                x = <np.int64_t> (o.center[0] + (i-1)*o.box_length)
                y = <np.int64_t> (o.center[1] + (j-1)*o.box_length)

                if i == j == 1:
                    continue

                if (self.xmin <= x and x <= self.xmax) and (self.ymin <= y and y <= self.ymax):

                    # compute hilbert key for each node neighbor node (inculding itself)
                    neighbor_oct_key = hilbert_key_2d(x, y, self.order)

                    # find neighbor oct that is at max the same level
                    neighbor = self.find_oct_by_key_level(neighbor_oct_key, o.level)

                    if neighbor.sfc_key not in node_set:

                        node_set.add(neighbor.sfc_key)

                        # check if their are sub octs, if so collet them too
                        if neighbor.children != NULL:
                            self.subneighbor_find(oct_list, neighbor, i, j)
                        else:
                            oct_list.append([neighbor.center[0], neighbor.center[1], neighbor.box_length,\
                                    neighbor.level, neighbor.particle_index_start, neighbor.number_particles])

        return oct_list



    cdef iterate(self, Oct* o, list data_list):

        data_list.append([o.center[0], o.center[1], o.box_length,
            o.level, o.particle_index_start, o.number_particles])

        cdef int i
        if o.children != NULL:
            for i in range(4):
                self.iterate(&o.children[i], data_list)


    def dump_data(self):
        cdef list data_list = []
        self.iterate(self.root, data_list)
        return data_list


    cdef void free_octs(self, Oct* o):
        cdef int i
        if o.children != NULL:
            for i in range(4):
                self.free_octs(&o.children[i])
            stdlib.free(o.children)


    def __dealloc__(self):
        self.free_octs(self.root)
        stdlib.free(self.root)

#    def find_oct_by_key(self, key):
#
#        cdef Oct* p = self._find_oct_by_key(key, self.root)
#        return [p.center[0], p.center[1], p.box_length,
#            p.level, p.particle_index_start, p.number_particles]
#
#
#    cdef Oct* _find_oct_by_key(self, np.uint64_t key, Oct* o):
#
#        if o.leaf == 1:
#            return o
#        else:
#            for i in range(4):
#                if o.children[i].sfc_start_key <= key and\
#                        key < (o.children[i].sfc_start_key + o.children[i].number_sfc_keys):
#                    return self._find_oct_by_key(key, &o.children[i])
#
#
#    cdef void find_leaves(self, Oct* o, list data_list):
#
#        cdef int i
#
#        if o.leaf == 1:
#
#            # find if oct is on the boundary 
#            for i in range(-1,2):
#                for j in range(-1,2):
#
#                    x = <np.uint32_t>(oct_key.center[0] + i*oct_key.box_length/4.0)
#                    y = <np.uint32_t>(oct_key.center[1] + j*oct_key.box_length/4.0)
#
#                    if (self.x_min < x and x < self.x_max) and (self.y_min < y and y < self.y_max):
#
#                        # compute hilbert key for each node neighbor node (inculding itself)
#                        oct_key = hilbert_key_2d(x, y, self.order)
#
#                        if oct_key < self.start_key and self.end_key < oct_key:
#
#                            data_list.append([o.center[0], o.center[1], o.box_length,
#                                o.level, o.particle_index_start, o.number_particles])
#
#        if o.children != NULL:
#            for i in range(4):
#                self.find_leaves(&o.children[i], data_list)




#                    # starting key and oct
#                    oct_key = p.sfc_key
#                    ancestor_oct = p
#
#                    while oct_key != neighbor_oct_key:
#
#                        # shift keys until they are equal, this happens
#                        # at the common ancestor oct
#                        oct_key = (oct_key << 2)
#                        neighbor_oct_key = (neighbor_oct_key << 2)
#
#                        # go up the parent oct
#                        ancestor_oct = ancestor_oct.parent