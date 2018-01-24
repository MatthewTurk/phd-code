import phd
import numpy as np

from libc.math cimport fmin
from cython.operator cimport preincrement as inc

from ..utils.tools import check_class
from ..utils.particle_tags import ParticleTAGS

cdef int REAL = ParticleTAGS.Real
cdef int GHOST = ParticleTAGS.Ghost
cdef int Exterior = ParticleTAGS.Exterior

cdef dict fields_for_parallel = {
        "key": "longlong",
        "process": "long",
        }

cdef class DomainManager:
    def __init__(self, double initial_radius,
                 double search_radius_factor=2.0, **kwargs):

        self.initial_radius = initial_radius
        self.search_radius_factor = search_radius_factor

        self.domain = None
        self.load_balance = None
        self.boundary_condition = None

        self.particle_fields_registered = False

        # list of particle to create ghost particles from
        self.flagged_particles.clear()

        if phd._in_parallel:

            # mpi send/receive counts
            self.send_cnts = np.zeros(phd._size, dtype=np.int32)
            self.recv_cnts = np.zeros(phd._size, dtype=np.int32)

            # mpi send/recieve displacements
            self.send_disp = np.zeros(phd._size, dtype=np.int32)
            self.recv_disp = np.zeros(phd._size, dtype=np.int32)

    def register_fields(self, CarrayContainer particles):
        """Register mesh fields into the particle container (i.e.
        volume, center of mass)

        Parameters
        ----------
        """
        cdef str field, dtype
        cdef int num_particles = particles.get_carray_size()

        if phd._in_parallel:
            for field, dtype in fields_for_parallel.iteritems():
                if field not in particles.carrays.keys():
                    particles.register_carray(num_particles, field, dtype)

        particles.register_carray(num_particles, "map", "long")
        particles.register_carray(num_particles, "radius", "double")
        particles.register_carray(num_particles, "old_radius", "double")

        # set initial radius for mesh generation
        self.setup_initial_radius(particles)
        self.particle_fields_registered = True

    def initialize(self):
        if not self.particle_fields_registered:
            raise RuntimeError("ERROR: Fields not registered in particles by Mesh!")

        if not self.domain or not self.boundary_condition:
                #not self.load_balance or
            raise RuntimeError("Not all setters defined in DomainMangaer")

    #@check_class(phd.DomainLimits)
    def set_domain_limits(self, domain):
        '''add boundary condition to list'''
        self.domain = domain

    #@check_class(phd.BoundaryConditionBase)
    def set_boundary_condition(self, boundary_condition):
        '''add boundary condition to list'''
        self.boundary_condition = boundary_condition

    #@check_class(phd.LoadBalance)
    def set_load_balance(self, load_balance):
        '''add boundary condition to list'''
        self.load_balance = load_balance

    cpdef check_for_partition(self, CarrayContainer particles):
        """
        Check if partition needs to called
        """
        pass

    cpdef partition(self, CarrayContainer particles):
        """
        Distribute particles across processors.
        """
        pass

    cpdef setup_initial_radius(self, CarrayContainer particles):
        """At the start of the simulation assign every particle an
        initial radius used for constructing the mesh. This values
        gets updated after each mesh build.

        Parameters
        ----------
        particles : CarrayContainer
            Class that holds all information pertaining to the particles.

        """
        cdef int i
        cdef DoubleArray r = particles.get_carray("radius")
        cdef DoubleArray rold = particles.get_carray("old_radius")

        for i in range(particles.get_carray_size()):
            r.data[i] = self.initial_radius
            rold.data[i] = self.initial_radius

    cpdef setup_for_ghost_creation(self, CarrayContainer particles):
        """Go through each particle and flag for ghost creation. For particles
        with infinite radius use domain size (serial) or partition tile
        (parallel) as initial search radius.

        Parameters
        ----------
        particles : CarrayContainer
            Class that holds all information pertaining to the particles.

        """
        cdef int i, k, dim
        cdef FlagParticle *p
        cdef double search_radius
        cdef np.float64_t *x[3], *mv[3]
        cdef DoubleArray r = particles.get_carray("radius")
        cdef DoubleArray rold = particles.get_carray("old_radius")

        dim = len(particles.carray_named_groups["position"])

        particles.pointer_groups(x, particles.carray_named_groups["position"])
        particles.pointer_groups(mv, particles.carray_named_groups["momentum"])

        # set ghost buffer to zero
        self.ghost_vec.clear()
        self.flagged_particles.resize(particles.get_carray_size(), FlagParticle())

        # there should be no ghost particles in the particle container

        i = 0
        cdef cpplist[FlagParticle].iterator it = self.flagged_particles.begin()
        while(it != self.flagged_particles.end()):

            # at this moment the radius of each particle should be
            # finite or infinte. for infinite radius use scaled radius
            # from previous time step. If finite the radius can still
            # be very large so we need to minimize it.
            if r.data[i] < 0:
                r.data[i] = self.search_radius_factor*rold.data[i]

            # populate with particle information
            p = particle_flag_deref(it)
            p.index = i

            # scale search radius from voronoi radius
            p.old_search_radius = 0.  # initial pass 
            p.search_radius = min(r.data[i], self.search_radius_factor*rold.data[i])

            # copy position and momentum, momentum is used because
            # after an update only the momentum is correct
            for k in range(dim):
                p.x[k] = x[k][i]
                p.v[k] = mv[k][i]

            # next particle
            inc(it)
            i += 1

    cpdef update_search_radius(self, CarrayContainer particles):
        """Go through each flag particle and update its radius. If
        the particle is still infinite double the search radius. If
        the new radius is smaller then the old search radius then that
        particle is done.

        Parameters
        ----------
        particles : CarrayContainer
            Class that holds all information pertaining to the particles.

        """
        cdef int i, k
        cdef FlagParticle *p
        cdef double search_radius
        cdef DoubleArray r = particles.get_carray("radius")

        # there should be no ghost particles
        cdef cpplist[FlagParticle].iterator it = self.flagged_particles.begin()
        while(it != self.flagged_particles.end()):

            # retrieve particle
            p = particle_flag_deref(it)
            i = p.index

            # at this point the radius of each particle has been
            # updated by the mesh

            if r.data[i] < 0: # infinite radius
                # grow until finite
                p.old_search_radius = p.search_radius
                p.search_radius = self.search_radius_factor*p.search_radius
                inc(it) # next particle

            else: # finite radius
                # if updated radius is smaller than
                # then search radius we are done
                if r.data[i] < p.search_radius:
                    it = self.flagged_particles.erase(it)
                else:
                    p.old_search_radius = p.search_radius
                    p.search_radius = self.search_radius_factor*r.data[i]
                    inc(it) # next particle

    cpdef create_ghost_particles(self, CarrayContainer particles):
        """After mesh generation, this method goes through partilce list
        and generates ghost particles and communicates them. This method
        is called by mesh repeatedly until the mesh is complete.

        Parameters
        ----------
        particles : CarrayContainer
            Class that holds all information pertaining to the particles.

        """
        cdef int i
        cdef FlagParticle *p

        self.ghost_vec.clear()

        # create particles from flagged particles
        cdef cpplist[FlagParticle].iterator it = self.flagged_particles.begin()
        while it != self.flagged_particles.end():

            # retrieve particle
            p = particle_flag_deref(it)

            # create ghost particles 
            self.boundary_condition.create_ghost_particle(p, self)
            self.create_interior_ghost_particle(p)
            inc(it)  # increment iterator

        # copy particles, put in processor order and export
        self.copy_particles(particles)

    cdef create_interior_ghost_particle(self, FlagParticle* p):
        """Create interior ghost particles to stitch back the solutions
        across processor.

        Parameters
        ----------
        particles : CarrayContainer
            Class that holds all information pertaining to the particles.

        """
        pass

    cdef copy_particles(self, CarrayContainer particles):
        """
        Copy particles that where flagged for ghost creation and append them
        into particle container.

        Parameters
        ----------
        particles : CarrayContainer
            Class that holds all information pertaining to the particles.

        """
        if phd._in_parallel:
            self.copy_particles_parallel(particles)
        else:
            self.copy_particles_serial(particles)

    cdef copy_particles_parallel(self, CarrayContainer particles):
        """Copy particles from ghost_particle vector in parallel run.

        Parameters
        ----------
        particles : CarrayContainer
            Class that holds all information pertaining to the particles.

        """
        raise RuntimeError("not implemented yet")

    cdef copy_particles_serial(self, CarrayContainer particles):
        """Copy particles from ghost_particle vector in serial run.

        Parameters
        ----------
        particles : CarrayContainer
            Class that holds all information pertaining to the particles.

        """
        cdef IntArray tags
        cdef LongArray maps
        cdef IntArray types

        cdef int i, k, dim
        cdef BoundaryParticle *p
        cdef CarrayContainer ghosts
        cdef LongArray indices = LongArray()

        cdef np.float64_t *xg[3], *mvg[3]

        dim = len(particles.carray_named_groups["position"])

        if self.ghost_vec.size() == 0:
            return

        # copy indices
        indices.resize(self.ghost_vec.size())
        for i in range(self.ghost_vec.size()):
            p = &self.ghost_vec[i]
            indices.data[i] = p.index

        # copy all particles to make ghost from
        ghosts = particles.extract_items(indices)

        tags  = ghosts.get_carray("tag")
        types = ghosts.get_carray("type")
        maps  = ghosts.get_carray("map")

        ghosts.pointer_groups(mvg, particles.carray_named_groups["momentum"])
        ghosts.pointer_groups(xg,  particles.carray_named_groups["position"])

        # transfer ghost position and velocity 
        for i in range(self.ghost_vec.size()):
            p = &self.ghost_vec[i]

            maps.data[i]  = p.index  # reference to image
            tags.data[i]  = GHOST    # ghost label
            types.data[i] = Exterior # ghost outside the domain

            for k in range(dim):

                # update values
                xg[k][i] = p.x[k]
                mvg[k][i] = p.v[k] # momentum not velocity

        # add new ghost to total ghost container
        particles.append_container(ghosts)

    cpdef bint ghost_complete(self):
        """Return True if no particles have been flagged for ghost
        creation.

        Particles that have been flagged for ghost creation are stored
        in flagged_particles. When flagged particles have a complete
        voronoi cell they are removed from flagged_particles.

        """
        if phd._in_parallel:
            raise RuntimeError("not implemented yet")
        else:
            return self.flagged_particles.empty()

    cpdef move_generators(self, CarrayContainer particles, double dt):
        """Move particles after flux update.

        Parameters
        ----------
        particles : CarrayContainer
            Class that holds all information pertaining to the particles.

        dt : float
            Time step of the simulation.

        """
        cdef int i, k, dim
        cdef np.float64_t *x[3], *wx[3]
        cdef IntArray tags = particles.get_carray("tag")
        cdef LongArray ids = particles.get_carray("ids")

        dim = len(particles.carray_named_groups['position'])
        particles.pointer_groups(x,  particles.carray_named_groups['position'])
        particles.pointer_groups(wx, particles.carray_named_groups['w'])

        for i in range(particles.get_carray_size()):
            if tags.data[i] == REAL:
                for k in range(dim):
                    x[k][i] += dt*wx[k][i]

        self.migrate_particles(particles)

    cpdef migrate_particles(self, CarrayContainer particles):
        """For particles that have left the domain or processor patch
        move particles to their appropriate spot.

        Parameters
        ----------
        particles : CarrayContainer
            Class that holds all information pertaining to the particles.

        """
        self.boundary_condition.migrate_particles(particles, self)


    cdef update_ghost_fields(self, CarrayContainer particles, list fields):
        """Transfer ghost fields from their image particle.

        After ghost particles are created their are certain fields that
        cannot be calculated (i.e. volume, center-of-mass ...) and need
        to be upated from their resepective image particle.

        Parameters
        ----------
        particles : CarrayContainer
            Container of particles.

        fields : list
            List of field strings to update

        """
        cdef int i
        cdef str field
        cdef LongArray indices = LongArray()
        cdef np.ndarray indices_npy, map_indices_npy
        cdef IntArray types = particles.get_carray("type")

        if phd._in_parallel:
            raise NotImplementedError("parallel update_ghost_fields not implemented yet")

        else:

            # find all ghost that need to be updated
            for i in range(particles.get_carray_size()):
                if types.data[i] == Exterior:
                    indices.append(i)

            if indices.length:

                indices_npy = indices.get_npy_array()
                map_indices_npy = particles["map"][indices_npy]

                # update ghost with their image data
                for field in fields:
                    particles[field][indices_npy] = particles[field][map_indices_npy]

    cdef update_ghost_gradients(self, CarrayContainer particles, CarrayContainer gradients):
        """Update ghost gradients from their mirror particle.

        After reconstruction only real particles have gradients calculated.
        This call will transfer those calcluated gradients to the respective
        ghost particles with appropriate updates from the boundary condition.

        Parameters
        ----------
        particles : CarrayContainer
            Container of particles.

        gradients : CarrayContainer
            Container of gradients for each primitive field.

        """
        cdef str field
        cdef LongArray indices = LongArray()
        cdef IntArray types = particles.get_carray("type")
        cdef np.ndarray indices_npy, map_indices_npy

        if phd._in_parallel:
            raise NotImplemented("parallel function called!")

        else:

            # find all ghost that are outside the domain that
            #need to be updated
            for i in range(particles.get_carray_size()):
                if types.data[i] == Exterior:
                    indices.append(i)

            # each ghost particle knows the id from which
            # it was created from the map array
            indices_npy = indices.get_npy_array()
            map_indices_npy = particles["map"][indices_npy]

            # update ghost gradient from image particle 
            for field in gradients.carray_named_groups["primitive"]:
                gradients[field][indices_npy] = gradients[field][map_indices_npy]

            # modify gradient by boundary condition
            self.boundary_condition.update_gradients(particles, gradients, self)

# ---------------------- add after serial working again -------------------------------
#cdef class DomainManager:
#    cdef filter_radius(self, CarrayContainer particles):
#        for i in range(particles.get_carray_size()):
#            if phd._in_parallel:
#                raise NotImplemented("filter_radius called")
#                if r.data[i] < 0.:
#                    r.data[i] = self.param_box_fraction*\
#                            self.load_balance.get_node_width(keys.data[i])
#
#    cdef copy_particles_parallel(CarrayContainer particles, vector[BoundaryParticle] ghost_vec):
#        """
#        Copy particles from ghost_particle vector
#        """
#        cdef CarrayContainer ghosts
#        cdef DoubleArray mass
#
#        cdef int i, j
#        cdef BoundaryParticle *p
#        cdef np.float64_t *x[3], *v[3], *mv[3]
#        cdef np.float64_t *xg[3], *vg[3], *mv[3]
#
#        # reset import/export counts
#        for i in range(self.size):
#            self.send_cnts[i] = 0
#            self.recv_cnts[i] = 0
#
#        if ghost_vec.size():
#
#            # sort particles in processor order
#            sort(ghost_vec.begin(), ghost_vec.end(), proc_cmp)
#
#            # copy indices
#            indices.resize(ghost_vec.size())
#            for i in range(ghost_vec.size()):
#                p = &ghost_vec[i]
#
#                indices.data[i] = p.index
#                self.send_cnts[p.proc] += 1
#
#            # transfer updated position and velocity
#            ghosts.pointer_groups(xg, particles.carray_named_groups['position'])
#            ghosts.pointer_groups(vg, particles.carray_named_groups['velocity'])
#            mass = ghosts.get_carray("mass")
#            ghosts.pointer_groups(mv, particles.carray_named_groups['momentum'])
#
#        # transfer new data to ghost 
#        for i in range(ghosts.get_carray_size()):
#            p = &ghost_vec[i]
#
#            # for ghost to retrieve info later 
#            maps.data[i] = p.index
#            for j in range(dim):
#
#                xg[j][i] = p.x[j]
#                vg[j][i] = p.v[j]
#                mv[j][i] = mass.data[i]*p.v[j]
#
#        # add new ghost to total ghost container
#        self.total_ghost_particles.append_container(exterior_ghost)
#
#        # create ghost particles from flagged particles
#        ghosts = particles.extract_items(indices)
#        self.load_bal.comm.Alltoall([self.send_cnts, MPI.INT],
#                [self.recv_cnts, MPI.INT])
#
#        # how many incoming particles
#        num_import = 0
#        for i in range(self.size):
#            num_import += self.recv_cnts[i]
#
#        # create displacement arrays 
#        self.send_disp[0] = self.recv_disp[0] = 0
#        for i in range(1, self.size):
#            self.send_disp[i] = self.send_cnts[i-1] + self.send_disp[i-1]
#            self.recv_disp[i] = self.recv_cnts[i-1] + self.recv_disp[i-1]
#
#        # send our particles / recieve particles 
#        self.exchange_particles(particles, ghosts,
#                self.send_cnts, self.recv_cnts,
#                0, self.comm,
#                self.pc.carray_named_groups['gravity-walk-export'],
#                self.send_disp, self.recv_disp)
#    cdef bint ghost_complete(self):
#        if phd._in_parallel:
#            raise RuntimeError("not implemented yet")
#            # let all processors know if walk is complete 
#            glb_done[0] = 0
#            loc_done[0] = self.export_interaction.done_processing()
#            self.load_bal.comm.Allreduce([loc_done, MPI.INT], [glb_done, MPI.INT], op=MPI.SUM)
#
#            return (self.new_exterior_flagged.empty() and\
#                    self.new_interior_flagged.empty())
#        else:
#            return True
