from pathlib import Path
import struct

WIDTH = 42.0
DEPTH = 26.0
BASE_HEIGHT = 12.0
WALL = 2.0
FLOOR = 1.6
USB_SLOT_WIDTH = 12.0
USB_SLOT_BOTTOM = 3.2
LID_THICKNESS = 2.0
LID_LIP_HEIGHT = 1.6
LID_CLEARANCE = 0.3


class RectilinearMesh:
    def __init__(self):
        self.operations = []

    def add(self, x0, y0, z0, x1, y1, z1):
        self.operations.append((True, (x0, y0, z0, x1, y1, z1)))

    def subtract(self, x0, y0, z0, x1, y1, z1):
        self.operations.append((False, (x0, y0, z0, x1, y1, z1)))

    def save(self, path, name):
        xs = sorted({value for _, box in self.operations for value in (box[0], box[3])})
        ys = sorted({value for _, box in self.operations for value in (box[1], box[4])})
        zs = sorted({value for _, box in self.operations for value in (box[2], box[5])})
        occupied = set()

        for add, box in self.operations:
            x0, y0, z0, x1, y1, z1 = box
            cells = set()
            for i in range(len(xs) - 1):
                if not x0 < (xs[i] + xs[i + 1]) / 2 < x1:
                    continue
                for j in range(len(ys) - 1):
                    if not y0 < (ys[j] + ys[j + 1]) / 2 < y1:
                        continue
                    for k in range(len(zs) - 1):
                        if z0 < (zs[k] + zs[k + 1]) / 2 < z1:
                            cells.add((i, j, k))
            if add:
                occupied |= cells
            else:
                occupied -= cells

        triangles = []
        for i, j, k in sorted(occupied):
            x0, x1 = xs[i], xs[i + 1]
            y0, y1 = ys[j], ys[j + 1]
            z0, z1 = zs[k], zs[k + 1]
            faces = [
                ((i - 1, j, k), (-1, 0, 0), [(x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0)]),
                ((i + 1, j, k), (1, 0, 0), [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)]),
                ((i, j - 1, k), (0, -1, 0), [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)]),
                ((i, j + 1, k), (0, 1, 0), [(x0, y1, z0), (x0, y1, z1), (x1, y1, z1), (x1, y1, z0)]),
                ((i, j, k - 1), (0, 0, -1), [(x0, y0, z0), (x0, y1, z0), (x1, y1, z0), (x1, y0, z0)]),
                ((i, j, k + 1), (0, 0, 1), [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)])
            ]
            for neighbor, normal, vertices in faces:
                if neighbor not in occupied:
                    triangles.append((normal, [vertices[index] for index in (0, 1, 2)]))
                    triangles.append((normal, [vertices[index] for index in (0, 2, 3)]))

        edges = {}
        for _, vertices in triangles:
            for first, second in ((0, 1), (1, 2), (2, 0)):
                edge = tuple(sorted((vertices[first], vertices[second])))
                edges[edge] = edges.get(edge, 0) + 1
        invalid_edges = sum(count != 2 for count in edges.values())
        if invalid_edges:
            raise RuntimeError(f"Mesh has {invalid_edges} non-manifold edges")

        with path.open("wb") as output:
            output.write(name.encode("ascii")[:80].ljust(80, b"\0"))
            output.write(struct.pack("<I", len(triangles)))
            for normal, vertices in triangles:
                output.write(struct.pack("<12fH", *normal, *(value for vertex in vertices for value in vertex), 0))

        print(f"{path.name}: {len(triangles)} triangles, {WIDTH} x {DEPTH} mm")


def base():
    mesh = RectilinearMesh()
    mesh.add(0, 0, 0, WIDTH, DEPTH, FLOOR)
    mesh.add(0, 0, 0, WALL, DEPTH, BASE_HEIGHT)
    mesh.add(WIDTH - WALL, 0, 0, WIDTH, DEPTH, BASE_HEIGHT)
    mesh.add(WALL, 0, 0, WIDTH - WALL, WALL, BASE_HEIGHT)
    mesh.add(WALL, DEPTH - WALL, 0, WIDTH - WALL, DEPTH, BASE_HEIGHT)

    for x0, x1 in ((3.0, 7.0), (35.0, 39.0)):
        for y0, y1 in ((3.0, 7.0), (19.0, 23.0)):
            mesh.add(x0, y0, FLOOR, x1, y1, 3.6)

    usb_y0 = (DEPTH - USB_SLOT_WIDTH) / 2
    mesh.subtract(-1, usb_y0, USB_SLOT_BOTTOM, WALL + 1, usb_y0 + USB_SLOT_WIDTH, BASE_HEIGHT + 1)

    for center in (8.0, 14.0, 20.0, 26.0, 32.0):
        for y0, y1 in ((-1.0, WALL + 1.0), (DEPTH - WALL - 1.0, DEPTH + 1.0)):
            mesh.subtract(center - 2.0, y0, 5.0, center + 2.0, y1, 9.0)
    return mesh


def lid():
    mesh = RectilinearMesh()
    mesh.add(0, 0, 0, WIDTH, DEPTH, LID_THICKNESS)
    mesh.add(
        WALL + LID_CLEARANCE,
        WALL + LID_CLEARANCE,
        LID_THICKNESS,
        WIDTH - WALL - LID_CLEARANCE,
        DEPTH - WALL - LID_CLEARANCE,
        LID_THICKNESS + LID_LIP_HEIGHT
    )
    mesh.subtract(
        WALL + LID_CLEARANCE + 2.0,
        WALL + LID_CLEARANCE + 2.0,
        LID_THICKNESS - 0.1,
        WIDTH - WALL - LID_CLEARANCE - 2.0,
        DEPTH - WALL - LID_CLEARANCE - 2.0,
        LID_THICKNESS + LID_LIP_HEIGHT + 1.0
    )

    for center in (9.0, 15.0, 21.0, 27.0, 33.0):
        mesh.subtract(center - 1.5, 6.0, -1.0, center + 1.5, 20.0, LID_THICKNESS + 1.0)
    return mesh


output_directory = Path(__file__).resolve().parent
base().save(output_directory / "pro-micro-case-base.stl", "Pro Micro case base")
lid().save(output_directory / "pro-micro-case-lid.stl", "Pro Micro case lid")
