# frozen_string_literal: true

class PagesController < ApplicationController
  allow_guest :home, :graph

  # Home (UI-2b): operator only, status only. Guests go to Search. The widgets load lazily, one
  # Turbo Frame each (home_section), so a slow check never holds up the page.
  def home
    redirect_to search_path and return if guest_signed_in?

    @sections = HomeSnapshot::SECTIONS
  end

  # GET /home/:section (Turbo Frame): one Home widget, from HomeSnapshot.section; 404 for an
  # unknown section (checked here, after the role check, so a guest still gets 403).
  def home_section
    section = params.require(:section)
    return head :not_found unless HomeSnapshot::SECTIONS.map(&:to_s).include?(section)

    render partial: "home/#{section}", locals: { data: HomeSnapshot.section(section), section: section }
  end

  def graph
    @vector_available = EmbeddingService.vector_enabled?
  end
end
