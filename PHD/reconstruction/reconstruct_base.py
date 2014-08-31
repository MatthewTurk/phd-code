
class ReconstructBase(object):
    """
    reconstruction base class, every reconstruction class must inherit
    this class
    """

    def __init__(self, boundary=None):
        self.gradx = None
        self.grady = None
        self.boundary = boundary

    def gradient(self, primitive, particles, particles_index, cell_info, neighbor_graph, neighbor_graph_sizes, face_graph, circum_centers):
        pass

    def extrapolate(self, faces_info, cell_com, gamma, dt):
        pass
