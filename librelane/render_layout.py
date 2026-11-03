"""Render a GDS layout to PNG with KLayout (batch mode).

    klayout -zz -r render_layout.py -rd gds=<file.gds> -rd lyp=<layers.lyp> -rd out=<file.png>
"""

import pya

view = pya.LayoutView()
view.load_layout(gds, 0)          # noqa: F821  (gds, lyp, out are injected by -rd)
view.load_layer_props(lyp)        # noqa: F821
view.set_config("background-color", "#ffffff")
view.set_config("grid-visible", "false")
view.max_hier()
view.zoom_fit()
view.save_image(out, 1400, 1400)  # noqa: F821
