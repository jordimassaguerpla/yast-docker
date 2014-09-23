# Copyright (c) 2014 SUSE LLC.
#  All Rights Reserved.

#  This program is free software; you can redistribute it and/or
#  modify it under the terms of version 2 or 3 of the GNU General
# Public License as published by the Free Software Foundation.

#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.   See the
#  GNU General Public License for more details.

#  You should have received a copy of the GNU General Public License
#  along with this program; if not, contact SUSE LLC.

#  To contact Novell about this file by physical or electronic mail,
#  you may find current contact information at www.suse.com

require "yast"
require "docker"

require "ydocker/changes_dialog"
require "ydocker/commit_dialog"
require "ydocker/run_image_dialog"

module YDocker
  class MainDialog
    include Yast::UIShortcuts
    include Yast::I18n
    include Yast::Logger

    def self.run
      Yast.import "UI"
      Yast.import "Popup"
      Yast.import "Storage"

      dialog = self.new
      dialog.run
    end

    def initialize
      textdomain "docker"

      read_containers
    end

    def run
      return unless create_dialog

      begin
        return controller_loop
      ensure
        close_dialog
      end
    end

  private
    DEFAULT_SIZE_OPT = Yast::Term.new(:opt, :defaultsize)

    def create_dialog
      Yast::UI.OpenDialog DEFAULT_SIZE_OPT, dialog_content
      update_images_buttons
    end

    def close_dialog
      Yast::UI.CloseDialog
    end

    def read_containers
      @containers = [] # TODO
    end

    def controller_loop
      while true do
        input = Yast::UI.UserInput
        case input
        when :ok, :cancel
          return :ok
        when :container_stop
          stop_container
          update_containers_buttons
        when :container_kill
          kill_container
          update_containers_buttons
        when :containers_redraw
          redraw_containers
          update_containers_buttons
        when :images_redraw
          redraw_images
        when :container_changes
          ChangesDialog.new(selected_container).run
        when :container_commit
          CommitDialog.new(selected_container).run
        when :images
          Yast::UI::ReplaceWidget(:tabContent, images_page)
        when :containers
          Yast::UI::ReplaceWidget(:tabContent, containers_page)
          update_containers_buttons
        when :image_delete
          image_delete
        when :images_table
          update_images_buttons
        when :image_run
          begin
            RunImageDialog.new(selected_image[0]).run
          rescue Docker::Error::DockerError => e
            log.errror "Docker exception #{e.inspect}"
            Yast::Popup.Error _("Failed to find selected image. Automatic refreshing image selection. Please try again.")
            redraw_images
            return
          end
        else
          raise "Unknown action #{input}"
        end
      end
    end

    def selected_container
      selected = Yast::UI.QueryWidget(:containers_table, :SelectedItems)
      selected = selected.first if selected.is_a? Array
      Docker::Container.get(selected)
    end

    def stop_container
      return unless (Yast::Popup.YesNo(_("Do you really want to stop the running container?")))
      selected_container.stop!
      selected_container.delete

      redraw_containers
    end

    def kill_container
      return unless (Yast::Popup.YesNo(_("Do you really want to kill the running container?")))
      selected_container.kill!
      selected_container.delete

      redraw_containers
    end

    def dialog_content
      VBox(
        DumbTab(
          [
            Item(Id(:images), _("&Images"), true),
            Item(Id(:containers), _("&Containers"))
          ],
          ReplacePoint(Id(:tabContent), images_page)
        ),
        ending_buttons
      )
    end

    def images_page
      VBox(
        Heading(_("Docker Images")),
        HBox(
          images_table,
          action_buttons_images
        )
      )
    end

    def containers_page
      VBox(
        Heading(_("Running Docker Containers")),
        HBox(
          containers_table,
          action_buttons_containers
        )
      )
    end

    def redraw_containers
      Yast::UI.ChangeWidget(:containers_table, :Items, containers_items)
    end

    def redraw_images
      Yast::UI.ChangeWidget(:images_table, :Items, images_items)
      update_images_buttons
    end

    def images_table
      Table(
        Id(:images_table),
        Opt(:notify),
        Header(
          _("Repository"),
          _("Tag"),
          _("Image ID"),
          _("Created"),
          _("Virtual Size")
        ),
       images_items
      )
    end

    def containers_table
      Table(
        Id(:containers_table),
        Header(
          _("Container ID"),
          _("Image"),
          _("Command"),
          _("Created"),
          _("Status"),
          _("Ports")
        ),
        containers_items
      )
    end

    def containers_items
      containers = Docker::Container.all
      containers.map do |container|
        Item(
          Id(container.id),
          container.id.slice(0,12),
          container.info["Image"],
          container.info["Command"],
          DateTime.strptime(container.info["Created"].to_s, "%s").to_s,
          container.info["Status"],
          container.info["Ports"].map {|p| "#{p["IP"]}:#{p["PublicPort"]}->#{p["PrivatePort"]}/#{p["Type"]}" }.join(",")
        )
      end
    end

    def images_items
      images = Docker::Image.all
      ret = []
      images.map do |image|
        image.info['RepoTags'].each do |repotag|
          repository, tag = repotag.split(":", 2)
          ret << Item(
            Id({:id => image.id, :label => repotag}),
            repository,
            tag,
            image.id.slice(0, 12),
            DateTime.strptime(image.info["Created"].to_s, "%s").to_s,
            Yast::Storage.ByteToHumanString(image.info["VirtualSize"])
          )
        end
      end
      ret
    end

    def action_button(id, title)
      Left(PushButton(Id(id), Opt(:hstretch), title))
    end

    def action_buttons_images
      HSquash(
        VBox(
          action_button(:images_redraw, _("Re&fresh")),
          action_button(:image_run, _("R&un")),
          action_button(:image_delete, _("&Delete"))
        )
      )
    end

    def action_buttons_containers
      HSquash(
        VBox(
          action_button(:containers_redraw, _("Re&fresh")),
          action_button(:containers_changes, _("S&how Changes")),
          action_button(:containers_stop, _("&Stop Container")),
          action_button(:containers_kill, _("&Kill Container")),
          action_button(:containers_commit, _("&Commit"))
        )
      )
    end

    def ending_buttons
      PushButton(Id(:ok), _("&Exit"))
    end

    def selected_image
      selected = Yast::UI.QueryWidget(:images_table, :SelectedItems)
      selected = selected.first if selected.is_a? Array
      [Docker::Image.get(selected[:id]), selected[:label]]
    end

    def image_delete
      begin
        image, label = selected_image
      rescue Docker::Error::DockerError => e
        log.errror "Docker exception #{e.inspect}"
        Yast::Popup.Error _("Failed to find selected image. Automatic refreshing image selection. Please try again.")
        redraw_images
        return
      end
      return unless (Yast::Popup.YesNo(_("Do you really want to delete image \"%s\"?") % label))

      image.remove
      redraw_images
    end

    def update_images_buttons
      is_something_selected = !Yast::UI.QueryWidget(:images_table, :SelectedItems).empty?
      [:image_run, :image_delete].each do |item|
        Yast::UI.ChangeWidget(item, :Enabled, is_something_selected)
      end
    end

    def update_containers_buttons
      is_something_selected = !Yast::UI.QueryWidget(:containers_table, :SelectedItems).empty?
      [:container_changes, :container_stop, :container_kill, :container_commit].each do |item|
        Yast::UI.ChangeWidget(item, :Enabled, is_something_selected)
      end
    end

  end
end
