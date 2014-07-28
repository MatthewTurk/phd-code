import numpy as np
from PHD.mesh import voronoi_mesh
from PHD.reconstruction.reconstruction_base import reconstruction_base
from PHD.riemann.riemann_base import riemann_base
from PHD.boundary.boundary_base import boundary_base

# for debug plotting 
from matplotlib.collections import LineCollection, PolyCollection, PatchCollection
from matplotlib.patches import Polygon
import matplotlib.pyplot as plt
import matplotlib


class moving_mesh(object):

    def __init__(self, gamma = 1.4, CFL = 0.5, max_steps=100, max_time=None,
            output_name="simulation_", regularization=False):

        # simulation parameters
        self.CFL = CFL
        self.gamma = gamma
        self.max_steps = max_steps
        self.max_time = max_time
        self.output_name = output_name
        self.regularization = regularization

        # particle information
        self.particles = None
        self.data = None
        self.cell_info = None

        self.particles_index = None
        self.voronoi_vertices = None
        self.neighbor_graph = None
        self.neighbor_graph_sizes = None
        self.face_graph = None
        self.face_graph_sizes = None

        # simulation classes
        self.mesh = voronoi_mesh(regularization)
        self.boundary = None
        self.reconstruction = None
        self.riemann_solver = None


    def _get_dt(self, time, prim, vol):
        """
        Calculate the time step using the CFL condition.
        """
        # sound speed
        c = np.sqrt(self.gamma*prim[3,:]/prim[0,:])

        # calculate approx radius of each voronoi cell
        R = np.sqrt(vol/np.pi)

        dt = self.CFL*np.min(R/c)

        if time + dt > self.max_time:
            dt = self.max_time - time

        return dt


    def _cons_to_prim(self, volume):
        """
        Convert volume integrated variables (density, densiy*velocity, Energy) to
        primitive variables (mass, momentum, pressure).
        """
        # conserative vector is mass, momentum, total energy
        mass = self.data[0,:]

        primitive = np.empty(self.data.shape, dtype=np.float64)
        primitive[0,:] = self.data[0,:]/volume      # density
        primitive[1:3,:] = self.data[1:3,:]/mass    # velocity

        # pressure
        primitive[3,:] = (self.data[3,:]/volume-0.5*self.data[0,:]*\
                (primitive[1,:]**2 + primitive[2,:]**2))*(self.gamma-1.0)

        return primitive



    def set_boundary_condition(self, boundary):

        if isinstance(boundary, boundary_base):
            self.boundary = boundary
        else:
            raise TypeError

    def set_reconstruction(self, reconstruction):

        if isinstance(reconstruction, reconstruction_base):
            self.reconstruction = reconstruction
        else:
            raise TypeError

    def set_initial_state(self, initial_particles, initial_data, initial_particles_index):
        """
        Set the initial state of the system by specifying the particle positions, their data
        U=(density, density*velocity, Energy) and particle labels (ghost or real).

        Parameters
        ----------
        initial_particles : Numpy array of size (dimensino, number particles)
        initial_data : Numpy array of conservative state vector U=(density, density*velocity, Energy)
            with size (variables, number particles)
        initial_particles_index: dictionary with two keys "real" and "ghost" that hold the indices
            in integer numpy arrays of real and ghost particles in the initial_particles array.
        """
        self.particles = initial_particles.copy()
        self.particles_index = dict(initial_particles_index)

        # make initial tesellation
        self.neighbor_graph, self.neighbor_graph_sizes, self.face_graph, self.face_graph_sizes, self.voronoi_vertices = self.mesh.tessellate(self.particles)

        # calculate volume of real particles 
        self.cell_info = self.mesh.volume_center_mass(self.particles, self.neighbor_graph, self.neighbor_graph_sizes, self.face_graph,
                self.voronoi_vertices, self.particles_index)

        # convert data to mass, momentum, and energy
        self.data = initial_data*self.cell_info["volume"]


    def set_riemann_solver(self, riemann_solver):

        if isinstance(riemann_solver, riemann_base):
            self.riemann_solver = riemann_solver
        else:
            raise TypeError("Unknown riemann solver")

    def set_parameter(self, parameter_name, parameter):

        if parameter_name in self.__dict__.keys():
            setattr(self, parameter_name, parameter)
        else:
            raise ValueError("Unknown parameter: %s" % parameter_name)

    def solve(self):
        """
        Evolve the simulation from time zero to the specified max time.
        """
        time = 0.0
        num_steps = 0

        while time < self.max_time and num_steps < self.max_steps:

            print "solving for step:", num_steps

            time += self._solve_one_step(time, num_steps)


            # debugging plot --- turn to a routine later ---
            l = []
            ii = 0; jj = 0
            for ip in self.particles_index["real"]:

                jj += self.neighbor_graph_sizes[ip]*2
                verts_indices = np.unique(self.face_graph[ii:jj])
                verts = self.voronoi_vertices[verts_indices]

                # coordinates of neighbors relative to particle p
                xc = verts[:,0] - self.particles[0,ip]
                yc = verts[:,1] - self.particles[1,ip]

                # sort in counter clock wise order
                sorted_vertices = np.argsort(np.angle(xc+1j*yc))
                verts = verts[sorted_vertices]

                l.append(Polygon(verts, True))

                ii = jj

            # add colormap
            colors = []
            for i in self.particles_index["real"]:
                colors.append(self.data[0,i]/self.cell_info["volume"][i])

            fig, ax = plt.subplots()
            p = PatchCollection(l, alpha=0.4)
            p.set_array(np.array(colors))
            p.set_clim([0, 4.])
            ax.add_collection(p)
            plt.colorbar(p)
            plt.savefig(self.output_name+`num_steps`.zfill(4))
            plt.clf()

            num_steps+=1



    def _solve_one_step(self, time, count):
        """
        Evolve the simulation for one time step.
        """

        # generate ghost particles with links to original real particles 
        self.particles = self.boundary.update(self.particles, self.particles_index, self.neighbor_graph, self.neighbor_graph_sizes)

        # make tesselation 
        self.neighbor_graph, self.neighbor_graph_sizes, self.face_graph, self.face_graph_sizes, self.voronoi_vertices = self.mesh.tessellate(self.particles)

        # calculate volume and center of mass of real particles
        self.cell_info = self.mesh.volume_center_mass(self.particles, self.neighbor_graph, self.neighbor_graph_sizes, self.face_graph,
                self.voronoi_vertices, self.particles_index)

        # calculate primitive variables of real particles
        primitive = self._cons_to_prim(self.cell_info["volume"])

        # calculate global time step from real particles
        dt = self._get_dt(time, primitive, self.cell_info["volume"])

        # assign primitive values to ghost particles
        primitive = self.boundary.primitive_to_ghost(self.particles, primitive, self.particles_index)

#--->
        # assign particle velocities to real and ghost and do mesh regularization
        w = self.mesh.assign_particle_velocities(self.particles, primitive, self.particles_index, self.cell_info, self.gamma)

        # calculate gradient of real particles
        grad = self.reconstruction.gradient()

        # assign gradient values to ghost particles
        grad = self.boundary.gradient_to_ghost(self.particles, grad, self.particles_index)

        # calculate states at edges
        left, right, faces_info = self.reconstruction.extrapolate(self.particles, primitive, grad, w, self.particles_index, self.neighbor_graph, self.neighbor_graph_sizes,
                self.face_graph, self.voronoi_vertices)

        # calculate reimann solution at edges 
        fluxes = self.riemann_solver.flux(left, right, faces_info, self.gamma)

        # update conserved variables
        self._update(fluxes, dt, faces_info)

        # move particles
        self.particles[:,self.particles_index["real"]] += dt*w[:, self.particles_index["real"]]

        return dt


    def _update(self, fluxes, dt, face_info):

        ghost_map = self.particles_index["ghost_map"]
        area = face_info[1,:]

        k = 0
        for i, j in zip(face_info[4,:], face_info[5,:]):

            self.data[:,i] -= dt*area[k]*fluxes[:,k]

            # do not update ghost particle cells
            if not ghost_map.has_key(j):
                self.data[:,j] += dt*area[k]*fluxes[:,k]

            k += 1
