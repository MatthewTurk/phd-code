import mesh
import itertools
import numpy as np
from scipy.spatial import Voronoi

from containers.containers import ParticleContainer

class VoronoiMeshBase(dict):
    """
    voronoi mesh base class
    """
    def __init__(self, particles, *arg, **kw):

        super(VoronoiMeshBase, self).__init__(*arg, **kw)
        self.particles = particles

    def tessellate(self):
        pass

    def update_boundary_particles(self):
        pass

class VoronoiMesh2D(VoronoiMeshBase):
    """
    2d voronoi mesh class
    """
    def __init__(self, particles, *arg, **kw):
        super(VoronoiMesh2D, self).__init__(particles, *arg, **kw)

        self["neighbors"] = None
        self["number of neighbors"] = None
        self["faces"] = None
        self["voronoi vertices"] = None

        face_vars = {
                "area": "double",
                "velocity-x": "double",
                "velocity-y": "double",
                "normal-x": "double",
                "normal-y": "double",
                "com-x": "double",
                "com-y": "double",
                "pair-i": "longlong",
                "pair-j": "longlong",
                }
        self.faces = ParticleContainer(var_dict=face_vars)

    def compute_cell_info(self):
        """
        compute volume and center of mass of all real particles and compute areas, center of mass, normal
        face pairs, and number of faces for faces
        """

        num_faces = mesh.number_of_faces(self.particles, self["neighbors"], self["number of neighbors"])
        self.faces.resize(num_faces)

        vol  = self.particles["volume"]
        xcom = self.particles["com-x"]
        ycom = self.particles["com-y"]

        vol[:] = 0.0
        xcom[:] = 0.0
        ycom[:] = 0.0

        mesh.cell_face_info_2d(self.particles, self.faces, self["neighbors"], self["number of neighbors"],
                self["faces"], self["voronoi vertices"])

    def update_boundary_particles(self):
        cumsum = np.cumsum(self["number of neighbors"], dtype=np.int32)
        mesh.flag_boundary_particles(self.particles, self["neighbors"], self["number of neighbors"], cumsum)

    def tessellate(self):
        """
        create 2d voronoi tesselation from particle positions
        """
        pos = np.array([
            self.particles["position-x"],
            self.particles["position-y"]
            ])

        # create the tesselation
        vor = Voronoi(pos.T)

        # total number of particles
        num_particles = self.particles.get_number_of_particles()

        # create neighbor and face graph
        neighbor_graph = [[] for i in xrange(num_particles)]
        face_graph = [[] for i in xrange(num_particles)]

        # loop through each face collecting the two particles
        # that made that face as well as the face itself
        for i, face in enumerate(vor.ridge_points):

            p1, p2 = face
            neighbor_graph[p1].append(p2)
            neighbor_graph[p2].append(p1)

            face_graph[p1] += vor.ridge_vertices[i]
            face_graph[p2] += vor.ridge_vertices[i]

        # sizes for 1d graphs
        neighbor_graph_sizes = np.array([len(n) for n in neighbor_graph], dtype=np.int32)

        # graphs in 1d
        neighbor_graph = np.array(list(itertools.chain.from_iterable(neighbor_graph)), dtype=np.int32)
        face_graph = np.array(list(itertools.chain.from_iterable(face_graph)), dtype=np.int32)

        self["neighbors"] = neighbor_graph
        self["number of neighbors"] = neighbor_graph_sizes
        self["faces"] = face_graph
        self["voronoi vertices"] = vor.vertices