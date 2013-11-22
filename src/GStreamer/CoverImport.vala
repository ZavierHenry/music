// -*- Mode: vala; indent-tabs-mode: nil; tab-width: 4 -*-
/*-
 * Copyright (c) 2012 Noise Developers (http://launchpad.net/noise)
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the
 * Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA.
 *
 * Authored by: Scott Ringwelski <sgringwe@mtu.edu>,
 *              Corentin Noël <tintou@mailoo.org>
 */

public class Noise.CoverImport : GLib.Object {
    private const int DISCOVER_SET_SIZE = 50;
    private const int DISCOVERER_TIMEOUT_MS = 10;

    private Gst.PbUtils.Discoverer d = null;
    private Gee.LinkedList<Media> uri_queue;
    private Gee.LinkedList<Media> original_queue;

    private bool cancelled;

    public CoverImport () {
        uri_queue = new Gee.LinkedList<Media> ();
        original_queue = new Gee.LinkedList<Media> ();
    }

    private void file_set_finished () {
        if (cancelled) {
            debug ("import cancelled");
            d.stop ();
            libraries_manager.local_library.media_imported (original_queue);
            original_queue.clear ();
        } else if (uri_queue.size == 0) {
            debug ("queue finished");
            d.stop ();
            libraries_manager.local_library.media_imported (original_queue);
            original_queue.clear ();
        } else {
            import_next_file_set.begin ();
        }
    }

    private async void import_next_file_set () {
        if (d == null) {
            try {
                d = new Gst.PbUtils.Discoverer ((Gst.ClockTime) (10 * Gst.SECOND));
            } catch (Error err) {
                critical ("Could not create Gst discoverer object: %s", err.message);
            }

            d.discovered.connect (import_media);
            d.finished.connect (file_set_finished);
        } else {
            d.stop ();
        }
        d.start ();

        for (int i = 0; i < DISCOVER_SET_SIZE; i++) {
            bool not_found = true;
            string uri = null;
            while (uri == null && !uri_queue.is_empty) {
                uri = uri_queue.poll_head ().uri;
                if (uri != null) {
                    d.discover_uri_async (uri);
                    not_found = false;
                }
            }
        }
    }

    public void cancel_operations () {
        cancelled = true;
    }

    public void discoverer_import_media (Gee.Collection<Media> uris) {
        cancelled = false;
        lock (uri_queue) {
            uri_queue.clear ();
            uri_queue.add_all (uris);
            original_queue.add_all (uris);
        }
        import_next_file_set.begin ();
    }

    private async void import_media (Gst.PbUtils.DiscovererInfo info, Error err) {

        string uri = info.get_uri ();

        bool gstreamer_discovery_successful = false;

        switch (info.get_result ()) {
            case Gst.PbUtils.DiscovererResult.OK:
                gstreamer_discovery_successful = true;
            break;

            case Gst.PbUtils.DiscovererResult.URI_INVALID:
                warning ("GStreamer could not import '%s': invalid URI.", uri);
            break;

            case Gst.PbUtils.DiscovererResult.ERROR:
                warning ("GStreamer could not import '%s': %s", uri, err.message);
            break;

            case Gst.PbUtils.DiscovererResult.TIMEOUT:
                warning ("GStreamer could not import '%s': Discovery timed out.", uri);
            break;

            case Gst.PbUtils.DiscovererResult.BUSY:
                warning ("GStreamer could not import '%s': Already discovering a file.", uri);
            break;

            case Gst.PbUtils.DiscovererResult.MISSING_PLUGINS:
                warning ("GStreamer could not import '%s': Missing plugins.", uri);

                /**
                 * TODO: handle this gracefully.
                 * After the import finishes, show the plugin-not-found
                 * dialog and rescan the music folder.
                 */
            break;
        }

        if (gstreamer_discovery_successful) {
            debug ("Importing with GStreamer: %s", uri);

            var m = libraries_manager.local_library.media_from_uri (uri);

            // Get cover art
            if (m != null)
                import_art_async.begin (m, info);
        }

    }

    private async void import_art_async (Media m, Gst.PbUtils.DiscovererInfo info) {
        var cache = CoverartCache.instance;
        if (cache.has_image (m))
            return;

        var pix = get_image (info.get_tags ());

        if (pix != null)
            cache.cache_image_async.begin (m, pix);
        else
            warning ("Could not find embedded image for '%s'", info.get_uri ());
            
    }

    private static Gdk.Pixbuf? get_image (Gst.TagList tag) {
        Gst.Buffer? buffer = null;

        for (int i = 0; ; i++) {
            Gst.Sample? loop_sample = null;
            if (!tag.get_sample_index (Gst.Tags.IMAGE, i, out loop_sample))
                break;

            if (loop_sample == null)
                continue;

            var structure = loop_sample.get_caps ().get_structure (0).copy ();
            if (structure == null)
                continue;

            int image_type;
            structure.get_enum ("image-type", typeof (Gst.Tag.ImageType), out image_type);

            if (image_type == Gst.Tag.ImageType.FRONT_COVER) {
                buffer = loop_sample.get_buffer ();
                break;
            } else if (image_type == Gst.Tag.ImageType.UNDEFINED || buffer == null) {
                buffer = loop_sample.get_buffer ();
            }
        }

        if (buffer == null) {
            debug ("Final image buffer is null");
            return null;
        }

        return get_pixbuf_from_buffer (buffer);
    }

    private static Gdk.Pixbuf? get_pixbuf_from_buffer (Gst.Buffer buffer) {
        var memory = buffer.get_memory (0);
        if (memory == null)
            return null;
 
        Gst.MapInfo map_info;
        if (!memory.map (out map_info, Gst.MapFlags.READ))
            return null;
 
        Gdk.Pixbuf? pix = null;
 
        if (map_info.data != null) {
            var loader = new Gdk.PixbufLoader ();
 
            try {
                if (loader.write (map_info.data))
                    pix = loader.get_pixbuf ();
                loader.close ();
            } catch (Error err) {
                warning ("Error processing image data: %s", err.message);
            }
        }
 
        memory.unmap (map_info);
 
        return pix;
    }

}
