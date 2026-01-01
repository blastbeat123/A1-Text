#!/usr/bin/env ruby
# SPDX-License-Identifier: LicenseRef-blastbeat-NC-NoAI-CodebergRef-2025
# encoding: utf-8 
# frozen_string_literal: true

# Autore: Giuseppe Bassan  2025
# Word Processor ispirato a C1-Text per Amiga
# Versione GTK4


ENV['GTK_IM_MODULE'] = 'gtk-im-context-simple'
ENV["GSK_RENDERER"] = "gl"

require 'gtk4'
require 'thread'
require 'net/http'
require 'json'
require 'open3'
require 'httpx'
require 'yaml'
require 'gosu'

class GrammarChecker
  def initialize(host: 'localhost', port: 8081)
    @uri = URI("http://#{host}:#{port}/v2/check")
  end

  def check_text(text)
    return [] if text.strip.empty?

    request = Net::HTTP::Post.new(@uri)
    request.set_form_data({
      'language' => 'it',
      'text' => text
    })

    response = Net::HTTP.start(@uri.hostname, @uri.port) do |http|
      http.request(request)
    end

    parse_response(JSON.parse(response.body))
  rescue StandardError => e
    puts "Grammar check error: #{e.message}"
    []
  end

  private

  def parse_response(json)
    json['matches'].map do |match|
      {
        error_text: match['context']['text'][match['offset'], match['length']],
        message: match['message'],
        suggestions: match['replacements'].map { |r| r['value'] },
        position: match['offset'],
        length: match['length']
      }
    end
  end
end

class Wordprocessor
  # 1. Carica il file di configurazione una sola volta quando la classe viene definita.
  #    Se il file non esiste o è invalido, CONFIG sarà un hash vuoto.
  begin
    CONFIG = YAML.load_file('config.yml') || {}
  rescue Errno::ENOENT
    puts "ATTENZIONE: File 'config.yml' non trovato. Verranno usate le impostazioni predefinite."
    CONFIG = {}
  rescue StandardError => e
    # In un'app reale, qui potresti mostrare un dialogo di errore,
    # ma all'avvio è più sicuro stampare su console e continuare con i default.
    puts "ERRORE nella lettura di 'config.yml': #{e.message}. Verranno usate le impostazioni predefinite."
    CONFIG = {}
  end

  # Font dei menu (con valori di default sicuri)
  MENU_FONT_FAMILY = CONFIG.dig('ui_settings', 'menu_font_family') || 'monospace'
  MENU_FONT_SIZE   = CONFIG.dig('ui_settings', 'menu_font_size')   || 10

  CUSTOM_CSS = <<-CSS
   .blue-caret-editor {
     caret-color: #1E88E5;
   }
  
   .overwrite-red {
     caret-color: #E53935;
   }
  
   /* 🎨 Font per i menu a tendina e la barra dei menu (da config.yml) */
     menubar, popover, menuitem, label {
     font-family: '#{MENU_FONT_FAMILY}';
     font-size: #{MENU_FONT_SIZE}pt;
   }

   /* Se vuoi differenziare la barra principale dal menu a tendina */
   menubar {
     font-weight: bold;
   }
  
  CSS

  AUTOSAVE_INTERVAL = 300 # 5 minuti in secondi

  #  Estrai i valori dalla configurazione, fornendo sempre un valore di default.
  #  Questo pattern è molto sicuro. Se la chiave non esiste in CONFIG, viene usato il valore dopo `||`.

  # Estrai il simbolo di Invio
  ENTER_SYMBOL = CONFIG.dig('ui_settings', 'enter_symbol') || "\u21B5" # Simbolo ↵

  # Possiamo spostare qui anche le altre configurazioni "globali".
  LANGUAGETOOL_PORT_DEFAULT = CONFIG.dig('languagetool', 'port') || 8081
  # Estrai il percorso di LanguageTool con un default
  LANGUAGETOOL_PATH = CONFIG.dig('languagetool', 'path') || '/usr/share/languagetool'
  
  def initialize
    @app = Gtk::Application.new('it.blastbeat.wordprocessor', Gio::ApplicationFlags::FLAGS_NONE)
    
    # Carica il CSS personalizzato globalmente
    css_provider = Gtk::CssProvider.new
    css_provider.load_from_data(CUSTOM_CSS)
    Gtk::StyleContext.add_provider_for_display(
      Gdk::Display.default,
      css_provider,
      Gtk::StyleProvider::PRIORITY_APPLICATION
    )
    
    # Imposta uno stato predefinito per le funzionalità AI
    @ai_configured = false
    @groq_api_key = nil
    @groq_api_url = CONFIG.dig('groq_api', 'url') || 'https://api.groq.com/openai/v1/chat/completions'
    @groq_model = CONFIG.dig('groq_api', 'model') || 'llama-3.3-70b-versatile'

    api_key_from_file = CONFIG.dig('groq_api', 'api_key')
    if api_key_from_file && !api_key_from_file.empty? && api_key_from_file != "b"
      @groq_api_key = api_key_from_file
      @ai_configured = true
      puts "Configurazione AI caricata correttamente."
    else
      puts "Chiave API non trovata o non valida. Funzionalità AI disabilitate."
    end

    @languagetool_port = LANGUAGETOOL_PORT_DEFAULT # Imposta la variabile d'istanza
    
    @current_font_family = 'IBM Plex Mono'
    @current_font_size = 13
    
    @word_completion_popover = nil
    @word_completion_listbox = nil
    @word_completion_active = false
    @word_completion_enabled = false # <-- RIGA AGGIUNTA
    @completion_timeout_id = nil # <-- RIGA AGGIUNTA
    
    @replacements = {}
    @replacement_enabled = true
    @capitalize_next = false # Flag per capitalizzare la prossima lettera
    @after_period = false # Flag per gestire il comportamento dopo il punto
    @last_period_position = nil # Posizione dell'ultimo punto inserito
    
    load_replacements
    
    @sound_enabled = false
    sound_file_path = 'click.wav'
    sound_file_path2 = 'click2.wav'
    
    @sound_player = SoundPlayer.new(sound_file_path)
    @notification_sound = SoundPlayer.new(sound_file_path2)
    
    # Variabili per autosave
    @autosave_enabled = false
    @autosave_timeout_id = nil
    
    @replacement_popover = nil
    @replacement_timeout_id = nil  # AGGIUNGI QUESTA RIGA
    
    #@replacement_notification = nil
    @nosound_keys = [
      "Shift_L", "Shift_R", "Control_L", "Control_R",
      "Alt_L", "Alt_R", "Super_L", "Super_R", "ISO_Level3_Shift",
      "Left", "Right", "Up", "Down"
    ].map { |name| Gdk::Keyval.from_name(name) }
    


    @grammar_checker = GrammarChecker.new(port: @languagetool_port)
    @grammar_check_enabled = false
    @grammar_check_thread = nil
    @error_tags = {} # Usiamo un Hash per associare dati ai tag

    @current_font_provider = nil
    @preview_font_provider = nil
    
    @app.signal_connect('activate') do |application|
      @languagetool_process = start_languagetool_server
      
      @root = Gtk::ApplicationWindow.new(application)
      @root.signal_connect('close-request') do
        check_unsaved_changes(:quit)
        true  # Blocca la chiusura predefinita - sarà gestita da perform_quit
      end
                             
      @root.set_default_size(1200, 900)
      @root.set_resizable(false)
    
      @main_box = Gtk::Box.new(Gtk::Orientation::VERTICAL, 0)
      @root.set_child(@main_box)
      
      setup_menu_bar
      setup_text_and_scrollbar
      setup_context_menu 
      update_window_title
      start_autosave
      
      @root.show
    end
       
    @app.run
  end

  def setup_text_and_scrollbar
    frame = Gtk::Box.new(Gtk::Orientation::HORIZONTAL, 0)
    frame.set_margin_top(10); frame.set_margin_bottom(10); frame.set_margin_start(10); frame.set_margin_end(10)
    
    @text = Gtk::TextView.new
    @text.set_wrap_mode(Gtk::WrapMode::WORD)
    @text.set_cursor_visible(true)
    @text.set_overwrite(false)
    @text.set_bottom_margin(200)
    @text.set_top_margin(10)
    @text.set_left_margin(10)
    @text.set_right_margin(10)
    
    # Aggiungi la classe CSS per il cursore blu
    @text.add_css_class('blue-caret-editor')

    # Gestisci il cambio di colore in modalità overwrite
    @text.signal_connect('notify::overwrite') do |widget|
      if widget.overwrite?
        widget.add_css_class('overwrite-red')
      else
        widget.remove_css_class('overwrite-red')
      end
    end
    
    tag_table = @text.buffer.tag_table
    @enter_symbol_tag = Gtk::TextTag.new('enter_symbol'); @enter_symbol_tag.foreground = 'red'; tag_table.add(@enter_symbol_tag)
    
    if @current_font_family && @current_font_size
      @current_font_provider = Gtk::CssProvider.new
      css_data = "textview { font-family: '#{@current_font_family}'; font-size: #{@current_font_size}pt; }"
      @current_font_provider.load_from_data(css_data)
      @text.style_context.add_provider(@current_font_provider, Gtk::StyleProvider::PRIORITY_APPLICATION)
    end
    
    key_controller = Gtk::EventControllerKey.new
    key_controller.signal_connect('key-pressed') do |controller, keyval, keycode, state|
      play_key_press_sound(keyval)
      handle_key_press(keyval, keycode, state)
    end
    @text.add_controller(key_controller)
    
    setup_mouse_motion_controller

    # Gestore UNIFICATO per sostituzioni E completamento
@text.buffer.signal_connect('insert-text') do |buffer, iter, text, len|
  if @replacement_enabled && text == ' '
    # Sostituzioni normali quando si preme spazio
    offset = iter.offset
    GLib::Idle.add { replace_word_on_space(offset); false }
  end
  
  # Gestisci il completamento parole per qualsiasi carattere
  # Lo facciamo in Idle per avere il buffer aggiornato
  GLib::Idle.add do
    handle_word_completion if @word_completion_enabled
    false
  end
end
    
    scrolled_window = Gtk::ScrolledWindow.new
    scrolled_window.set_policy(:automatic, :automatic); scrolled_window.set_child(@text)
    frame.append(scrolled_window)
    scrolled_window.set_hexpand(true); scrolled_window.set_vexpand(true)
    @main_box.append(frame)
    frame.set_hexpand(true); frame.set_vexpand(true)
  end

  def setup_context_menu
    # Crea un modello di menu SOLO per le nostre azioni AI
    ai_extra_menu = Gio::Menu.new
    ai_extra_menu.append('Sinonimo (AI)', 'app.ai_sinonimo')
    ai_extra_menu.append('Migliora testo (AI)', 'app.ai_migliora')
    ai_extra_menu.append('Riscrivi testo (AI)', 'app.ai_riscrivi')
    ai_extra_menu.append('Arrichisci testo (AI)', 'app.ai_arrichisci')

    # Assegna questo menu come "menu extra" al context menu predefinito del TextView.
    # GTK si occuperà di aggiungerlo automaticamente.
    @text.set_extra_menu(ai_extra_menu)
  end

  def handle_key_press(keyval, keycode, state)
    key_name = Gdk::Keyval.to_name(keyval)
    
    case key_name
    when "Return", "KP_Enter"
      handle_return_key
      return true
    when "guillemotright" # Virgolette chiuse »
      handle_closing_quote
      return true
      
      when "Escape"
  hide_word_completion
  return true

when "Tab"
  if @word_completion_active && @word_completion_listbox
    row = @word_completion_listbox.selected_row ||
          @word_completion_listbox.get_row_at_index(0)

    if row
      apply_completion(row.child.text, get_current_word)
      hide_word_completion
      return true
    end
  end
  return false
   
   
   when "Down"
  if @word_completion_active && @word_completion_listbox
    current_row = @word_completion_listbox.selected_row
    if current_row
      next_index = current_row.index + 1
      next_row = @word_completion_listbox.get_row_at_index(next_index)
      @word_completion_listbox.select_row(next_row) if next_row
    end
    return true  # ← Blocca comportamento default
  end
  return false

    when "Up"
    if @word_completion_active && @word_completion_listbox
      current_row = @word_completion_listbox.selected_row
      if current_row && current_row.index > 0
        prev_index = current_row.index - 1
        prev_row = @word_completion_listbox.get_row_at_index(prev_index)
        @word_completion_listbox.select_row(prev_row) if prev_row
      end
      return true  # ← Blocca comportamento default
    end
    return false
     
    when "question"  # Punto interrogativo ?
      return handle_question  # ← Usa il valore di ritorno del metodo
    when "exclam"  # Punto esclamativo !
      return handle_exclamation  # ← Usa il valore di ritorno del metodo
      
    when "period"
      return handle_period  # ← Usa il valore di ritorno del metodo
    when "comma"
      return handle_punctuation(',')  # ← Usa il valore di ritorno del metodo
    when "semicolon"
      return handle_punctuation(';')  # ← Usa il valore di ritorno del metodo
    when "colon"
      return handle_punctuation(':')  # ← Usa il valore di ritorno del metodo
    when "space"
      # Per lo spazio lasciamo che il normale meccanismo funzioni
      # La sostituzione avverrà tramite il segnale insert-text
      return false
    else
      # Gestisce le lettere per la capitalizzazione
      if key_name.length == 1 && key_name.match?(/[a-zA-Z]/)
        if handle_letter(key_name)
          return true
        end
      end
      
      # Reset dei flag per altri caratteri
      unless key_name == "Return" || key_name == "KP_Enter"
        @capitalize_next = false
      end
      
      return false
    end
  end
  
  def check_unsaved_changes(action_type)
    buffer = @text.buffer
    content = get_clean_buffer_content

    if content.strip.empty?
      perform_action(action_type)
      return
  end

  unless @current_file_path
    show_save_before_action_dialog(
      action_type,
      "Documento non salvato",
      "Il documento contiene modifiche non salvate.\n\nVuoi salvare prima di #{action_type == :quit ? 'uscire' : (action_type == :open ? 'aprire un altro file' : 'creare un nuovo documento')}?"
    )
    return
  end

  begin
    saved_content = File.read(@current_file_path)
    if saved_content != content
      show_save_before_action_dialog(
        action_type,
        "Modifiche non salvate",
        "Il file '#{File.basename(@current_file_path)}' è stato modificato.\n\nVuoi salvare prima di #{action_type == :quit ? 'uscire' : (action_type == :open ? 'aprire un altro file' : 'creare un nuovo documento')}?"
      )
    else
      perform_action(action_type)
    end
  rescue => e
    puts "Errore nel confronto file: #{e.message}"
    show_save_before_action_dialog(
      action_type,
      "Modifiche non salvate",
      "Il file potrebbe contenere modifiche non salvate.\n\nVuoi salvare prima di #{action_type == :quit ? 'uscire' : (action_type == :open ? 'aprire un altro file' : 'creare un nuovo documento')}?"
    )
  end
end

  def show_save_before_action_dialog(action_type, title, message)
    dialog = Gtk::MessageDialog.new(
      parent: @root, flags: :modal, type: :question,
      buttons: :none, message: message
    )
    dialog.set_title(title)
    dialog.add_button('Annulla', Gtk::ResponseType::CANCEL)
    dialog.add_button('No', Gtk::ResponseType::NO)
    dialog.add_button('Sì', Gtk::ResponseType::YES)
    dialog.set_default_response(Gtk::ResponseType::YES)

    dialog.signal_connect('response') do |d, response|
      case response
      when Gtk::ResponseType::YES
        if @current_file_path
          save_to_file(@current_file_path)
          perform_action(action_type)
        else
          save_as_file_before_action(action_type)
        end
      when Gtk::ResponseType::NO
        perform_action(action_type)
      else
        puts "#{action_type.capitalize} annullato dall'utente"
      end
      d.destroy
    end
    dialog.show
  end

  def show_save_dialog(title: 'Save File As', default_name: nil, callback: nil)
    dialog = Gtk::FileChooserDialog.new(
      title: title,
      parent: @root,
      action: :save
    )
    dialog.add_button('Annulla', Gtk::ResponseType::CANCEL)
    dialog.add_button('Salva', Gtk::ResponseType::ACCEPT)
  
    # Determina il nome predefinito da usare
    current_name = default_name || 
                   (@current_file_path ? File.basename(@current_file_path) : 'untitled.txt')
    dialog.set_current_name(current_name)
  
    dialog.signal_connect('response') do |d, res|
      if res == Gtk::ResponseType::ACCEPT
        path = d.file&.path
        if path
          if save_to_file(path)
            # Esegui il callback se fornito (es. per continuare con quit/open/new)
            callback.call if callback
          else
            show_error_dialog("Errore nel salvataggio del file.")
          end
        else
          show_error_dialog("Percorso non valido.")
        end
      end
      d.destroy
    end
  
    dialog.show
  end

  def save_as_file_before_action(action_type)
    # Mostra dialog con titolo appropriato e callback per continuare l'azione
    action_text = case action_type
                  when :quit then 'Uscire'
                  when :open then 'Aprire'
                  when :new then 'Creare Nuovo'
                  else 'Continuare'
                  end
  
    show_save_dialog(
      title: "Salva File Prima di #{action_text}",
      callback: -> { perform_action(action_type) }
    )
  end

  def perform_action(action_type)
    case action_type
    when :quit
      perform_quit
    when :open
      open_file_dialog
    when :new # Aggiungi la gestione per la nuova azione :new
      perform_new_file
    else
      puts "Azione sconosciuta: #{action_type}"
    end
  end

  
  def perform_quit
    puts "Chiusura applicazione..."
    stop_grammar_check_thread
    stop_languagetool_server
    stop_autosave
    @app.quit
  end
  
  def handle_return_key
    remove_space_after_period_if_needed

    buffer = @text.buffer
    cursor_iter = buffer.get_iter_at(:offset => buffer.cursor_position)

    # Salva la posizione PRIMA dell'inserimento
    insert_position = cursor_iter.offset

    # Inserisce il simbolo Enter e va a capo
    buffer.insert(cursor_iter, "#{ENTER_SYMBOL}\n")

    # Applica il tag al simbolo Enter usando la posizione salvata
    start_iter = buffer.get_iter_at(:offset => insert_position)
    end_iter = buffer.get_iter_at(:offset => insert_position + ENTER_SYMBOL.length)
    buffer.apply_tag(@enter_symbol_tag, start_iter, end_iter)

    @after_period = false
    
    # SOLUZIONE: Forza lo scroll al cursore
    # Dobbiamo usare GLib::Idle.add per assicurarci che l'aggiornamento
    # avvenga dopo che GTK ha completato il rendering
    GLib::Idle.add do
      @text.scroll_to_iter(buffer.get_iter_at(:offset => buffer.cursor_position), 
                           0.0,    # within_margin
                           false,  # use_align
                           0.0,    # xalign (non usato se use_align è false)
                           0.0)    # yalign (non usato se use_align è false)
      false # Esegui solo una volta
    end
  end

  def handle_closing_quote
    remove_space_after_period_if_needed
    
    buffer = @text.buffer
    cursor_iter = buffer.get_iter_at(:offset => buffer.cursor_position)
    buffer.insert(cursor_iter, '»')
    
    @after_period = false
  end

  # Metodo generico per gestire tutti i tipi di punteggiatura
  def handle_punctuation_with_space(punct_char, capitalize_next: false)
    return false unless @replacement_enabled
    
    buffer = @text.buffer
    cursor_iter = buffer.get_iter_at(:offset => buffer.cursor_position)
    
    # Prima controlla e sostituisce la parola se necessario
    word_replaced = replace_word_before_punctuation(punct_char)
    
    # Dopo la sostituzione, ri-ottieni la posizione del cursore
    cursor_iter = buffer.get_iter_at(:offset => buffer.cursor_position)
    
    # Inserisce la punteggiatura e lo spazio
    buffer.insert(cursor_iter, "#{punct_char} ")
    
    # Gestisce i flag speciali per punteggiatura che termina le frasi
    if capitalize_next
      @last_period_position = buffer.cursor_position - 2 # Posizione del carattere di punteggiatura
      @capitalize_next = true
      @after_period = true
    end
    
    # Mostra la notifica appropriata
    if word_replaced
      show_replacement_notification_popover("sostituita parola - inserito spazio")
    else
      show_replacement_notification_popover("inserito spazio")
    end
    
    true
  end

  def handle_period
    handle_punctuation_with_space('.', capitalize_next: true)
  end

  def handle_punctuation(punct_char)
    handle_punctuation_with_space(punct_char, capitalize_next: false)
  end

  def handle_exclamation
    handle_punctuation_with_space('!', capitalize_next: true)
  end

  def handle_question
    handle_punctuation_with_space('?', capitalize_next: true)
  end

  def handle_letter(key)
    if @capitalize_next
      buffer = @text.buffer
      cursor_iter = buffer.get_iter_at(:offset => buffer.cursor_position)
      buffer.insert(cursor_iter, key.upcase)
      @capitalize_next = false
      @after_period = false
      
      show_replacement_notification_popover("lettera maiuscola")
      puts "Lettera maiuscola inserita"
      return true
    end
    return false
  end

  def remove_space_after_period_if_needed
    return unless @last_period_position && @after_period
    
    buffer = @text.buffer
    current_pos = buffer.cursor_position
    
    # Controlla se c'è uno spazio dopo il punto
    if current_pos > @last_period_position + 1
      space_iter = buffer.get_iter_at(:offset => @last_period_position + 1)
      next_iter = buffer.get_iter_at(:offset => @last_period_position + 2)
      
      if buffer.get_text(space_iter, next_iter, false) == ' '
        buffer.delete(space_iter, next_iter)
        show_replacement_notification_popover("rimosso spazio")
        puts "Spazio dopo il punto rimosso"
      end
    end
    
    @last_period_position = nil
    @after_period = false
  end

  def replace_word_on_space(offset)
    # Gestione delle sostituzioni normali quando si preme spazio
    buffer = @text.buffer
    
    # L'offset punta alla posizione DOVE verrà inserito lo spazio
    # Dobbiamo trovare la parola prima di questa posizione
    cursor_iter = buffer.get_iter_at(:offset => offset)
    
    # Trova l'inizio e la fine della parola corrente
    word_start_iter = cursor_iter.dup
    word_end_iter = cursor_iter.dup
    
    # Vai all'inizio della parola corrente
    return unless word_start_iter.backward_word_start
    
    # Vai alla fine della parola corrente (che dovrebbe essere la posizione del cursore)
    word_end_iter.forward_word_end
    
    # La fine della parola dovrebbe corrispondere alla posizione del cursore
    # Se non corrisponde, aggiustiamo
    if word_end_iter.offset > offset
      word_end_iter = cursor_iter.dup
    end
    
    # Ottieni la parola
    word = buffer.get_text(word_start_iter, word_end_iter, false)
    return if word.strip.empty?
    
    # Cerca la sostituzione
    correct_base_word = @replacements[word.downcase]
    return unless correct_base_word
    
    # Determina se la parola originale era capitalizzata
    is_capitalized = word[0] == word[0].upcase
    final_word = is_capitalized ? correct_base_word.capitalize : correct_base_word
    
    # Sostituisce la parola
    buffer.begin_user_action
    buffer.delete(word_start_iter, word_end_iter)
    buffer.insert(word_start_iter, final_word)
    buffer.end_user_action
    
    show_replacement_notification_popover("sostituita parola")
    
    puts "Sostituito '#{word}' con '#{final_word}' (sostituzione normale)"
  end

  def replace_word_before_punctuation(punct_char)
    buffer = @text.buffer
    cursor_iter = buffer.get_iter_at(:offset => buffer.cursor_position)
    
    # Trova l'inizio della parola corrente
    word_start_iter = cursor_iter.dup
    return false unless word_start_iter.backward_word_start
    
    # Ottieni la parola
    word = buffer.get_text(word_start_iter, cursor_iter, false)
    return false if word.strip.empty?
    
    # Cerca la sostituzione
    correct_base_word = @replacements[word.downcase]
    return false unless correct_base_word
    
    # Determina se la parola originale era capitalizzata
    is_capitalized = word[0] == word[0].upcase
    final_word = is_capitalized ? correct_base_word.capitalize : correct_base_word
    
    # Sostituisce la parola
    buffer.begin_user_action
    buffer.delete(word_start_iter, cursor_iter)
    buffer.insert(word_start_iter, final_word)
    buffer.end_user_action
    
    puts "Sostituito '#{word}' con '#{final_word}' prima di '#{punct_char}'"
    return true
  end

  def setup_menu_bar
    menu_model = Gio::Menu.new
    file_submenu = Gio::Menu.new
    file_submenu.append('New', 'app.new') # Aggiungi la voce New
    file_submenu.append('Open', 'app.open')
    file_submenu.append('Save', 'app.save')
    file_submenu.append('Save As', 'app.save_as')
    file_submenu.append('Toggle Autosave 5 min', 'app.toggle_autosave')
    file_submenu.append('Exit', 'app.quit')
    menu_model.append_submenu('File', file_submenu)
    format_submenu = Gio::Menu.new
    format_submenu.append('Select Font...', 'app.select_font')
    menu_model.append_submenu('Format', format_submenu)
    ai_submenu = Gio::Menu.new
    ai_submenu.append('Sinonimo/Synonymous', 'app.ai_sinonimo')
    ai_submenu.append('Migliora testo/Improve text', 'app.ai_migliora')
    ai_submenu.append('Riscrivi testo/Rewrite text', 'app.ai_riscrivi')
    ai_submenu.append('Arrichisci testo/Enrich text', 'app.ai_arrichisci')
    menu_model.append_submenu('AI', ai_submenu)
    settings_submenu = Gio::Menu.new
    settings_submenu.append('Enable Word Replacement', 'app.toggle_replacement')
    settings_submenu.append('Enable Completion', 'app.toggle_word_completion') # <-- RIGA AGGIUNTA
    settings_submenu.append('Enable Sound', 'app.toggle_sound')
    
    settings_submenu.append('Enable Grammar Check', 'app.toggle_grammar_check')
  
    settings_submenu.append('Show Replacements List...', 'app.show_replacements')
    settings_submenu.append('Cleanup autosaves...', 'app.cleanup_autosaves')
  
    menu_model.append_submenu('Settings', settings_submenu)
    menu_bar = Gtk::PopoverMenuBar.new; menu_bar.set_menu_model(menu_model)
    setup_menu_actions
    @main_box.append(menu_bar)
  end

  def setup_menu_actions
    @app.add_action(Gio::SimpleAction.new('new', nil).tap { |a| a.signal_connect('activate') { new_file } }) # Nuova azione per "New"
    @app.add_action(Gio::SimpleAction.new('open', nil).tap { |a| a.signal_connect('activate') { open_file } })
    @app.add_action(Gio::SimpleAction.new('save', nil).tap { |a| a.signal_connect('activate') { save_file } })
    @app.add_action(Gio::SimpleAction.new('save_as', nil).tap { |a| a.signal_connect('activate') { save_as_file } })
    # Toggle Autosave Action
    toggle_autosave_action = Gio::SimpleAction.new('toggle_autosave', nil, GLib::Variant.new(@autosave_enabled))
    toggle_autosave_action.signal_connect('activate') do |a, p|
      new_state = !a.state
      @autosave_enabled = new_state
      a.set_state(GLib::Variant.new(new_state))
    
      if @autosave_enabled
        start_autosave
        puts "Autosave: abilitato"
      else
        stop_autosave
        puts "Autosave: disabilitato"
      end
    end
    @app.add_action(toggle_autosave_action)
    
    @app.add_action(Gio::SimpleAction.new('quit', nil).tap do |a|
      a.signal_connect('activate') do
        #puts "Uscita dal menu..."
        
         check_unsaved_changes(:quit)
      end
    end)
    
    @app.set_accels_for_action('app.save', ['<Control>s']); @app.set_accels_for_action('app.save_as', ['<Control><Shift>s']); @app.set_accels_for_action('app.quit', ['<Control>q'])
    
    @app.add_action(Gio::SimpleAction.new('ai_sinonimo', nil).tap { |a| a.signal_connect('activate') { process_selected_text_with_groq('sinonimo') } })
    @app.add_action(Gio::SimpleAction.new('ai_migliora', nil).tap { |a| a.signal_connect('activate') { process_selected_text_with_groq('migliora testo') } })
    @app.add_action(Gio::SimpleAction.new('ai_riscrivi', nil).tap { |a| a.signal_connect('activate') { process_selected_text_with_groq('riscrivi testo') } })
    @app.add_action(Gio::SimpleAction.new('ai_arrichisci', nil).tap { |a| a.signal_connect('activate') { process_selected_text_with_groq('arrichisci testo') } })
    
    @app.add_action(Gio::SimpleAction.new('select_font', nil).tap { |a| a.signal_connect('activate') { select_font } })
    @app.set_accels_for_action('app.select_font', ['<Control><Shift>f'])
    
    toggle_replacement_action = Gio::SimpleAction.new('toggle_replacement', nil, GLib::Variant.new(@replacement_enabled))
    toggle_replacement_action.signal_connect('activate') do |a, p|
      new_state = !a.state; @replacement_enabled = new_state; a.set_state(GLib::Variant.new(new_state))
      puts "Sostituzione parole: #{@replacement_enabled ? 'abilitata' : 'disabilitata'}"
    end
    @app.add_action(toggle_replacement_action)
    
    # --- BLOCCO AGGIUNTO ---
    toggle_completion_action = Gio::SimpleAction.new('toggle_word_completion', nil, GLib::Variant.new(@word_completion_enabled))
    toggle_completion_action.signal_connect('activate') do |a, p|
      new_state = !a.state
      @word_completion_enabled = new_state
      a.set_state(GLib::Variant.new(new_state))
      puts "Completamento parole: #{@word_completion_enabled ? 'abilitato' : 'disabilitato'}"
      
      # Se disabilitato, nascondi il popover se è visibile
      hide_word_completion unless @word_completion_enabled
    end
    @app.add_action(toggle_completion_action)
    # --- FINE BLOCCO AGGIUNTO ---
    
    
    toggle_sound_action = Gio::SimpleAction.new('toggle_sound', nil, GLib::Variant.new(@sound_enabled))
    toggle_sound_action.signal_connect('activate') do |a, p|
      new_state = !a.state; @sound_enabled = new_state; a.set_state(GLib::Variant.new(new_state))
      puts "Suono tasti: #{@sound_enabled ? 'abilitato' : 'disabilitato'}"
    end
    @app.add_action(toggle_sound_action)
    
    toggle_grammar_action = Gio::SimpleAction.new('toggle_grammar_check', nil, GLib::Variant.new(false))
    toggle_grammar_action.signal_connect('activate') do |action, _parameter|
      new_state = !action.state
      action.set_state(GLib::Variant.new(new_state)) # Corretto anche qui
      @grammar_check_enabled = new_state
      if @grammar_check_enabled
        start_grammar_check_thread
      else
        stop_grammar_check_thread
        #remove_all_error_tags
      end
      puts "Controllo grammaticale: #{@grammar_check_enabled ? 'abilitato' : 'disabilitato'}"
    end
    @app.add_action(toggle_grammar_action)
    
    @app.add_action(Gio::SimpleAction.new('show_replacements', nil).tap { |a| a.signal_connect('activate') { show_replacements_window } })
    @app.add_action(Gio::SimpleAction.new('cleanup_autosaves', nil).tap do |a|
      a.signal_connect('activate') { cleanup_autosaves_with_confirmation }
    end)
  end

  def load_replacements
    @replacements = {}; begin
      total_lines = 0
      File.foreach('replacements.txt') do |line|
        total_lines += 1; wrong, correct = line.chomp.split(' ', 2); next unless wrong && correct
        l_wrong = wrong.downcase; @replacements[l_wrong] = correct unless @replacements.key?(l_wrong)
      end
      puts "Lette #{total_lines} righe. Caricate #{@replacements.size} sostituzioni uniche."
    rescue Errno::ENOENT
      puts 'ATTENZIONE: File "replacements.txt" non trovato.'
    end
  end
  
  def show_replacements_window
    window = Gtk::Window.new
    window.set_title("Elenco Sostituzioni")
    window.set_default_size(350, 500)
    window.set_transient_for(@root)
    window.set_modal(true)
    
    window.signal_connect('close-request') do
      window.destroy
      true # Impedisce la gestione predefinita
    end
    
    scrolled_window = Gtk::ScrolledWindow.new
    scrolled_window.set_policy(:automatic, :automatic)
    
    text_view = Gtk::TextView.new
    text_view.set_editable(false)
    text_view.set_cursor_visible(false)
    text_view.set_wrap_mode(Gtk::WrapMode::WORD)
    
    # Applica un font più grande alla TextView
    css_provider = Gtk::CssProvider.new
    css_data = "textview { font-family: 'Courier'; font-size: 12pt; }"
    css_provider.load_from_data(css_data)
    text_view.style_context.add_provider(css_provider, Gtk::StyleProvider::PRIORITY_APPLICATION)
    
    buffer = text_view.buffer
    if File.exist?('replacements.txt')
      content = ""
      @replacements.each { |k, v| content += "#{k}  →  #{v}\n" }
      buffer.set_text(content)
    else
      buffer.set_text("File replacements.txt non trovato.")
    end
    
    scrolled_window.set_child(text_view)
    window.set_child(scrolled_window)
    window.show
  end

  def new_file # Nuovo metodo per l'azione "New"
    check_unsaved_changes(:new)
  end

  def perform_new_file
    @text.buffer.text = "" # Cancella il testo nel buffer
    @current_file_path = nil # Resetta il percorso del file corrente
    update_window_title # Aggiorna il titolo per riflettere il nuovo documento non salvato
    remove_all_error_tags # Rimuove eventuali tag di errore grammaticale
    # Se il controllo grammaticale era attivo, fermalo e riavvialo
    # per pulire eventuali errori non visibili e poi controllare il nuovo testo vuoto
    if @grammar_check_enabled
      stop_grammar_check_thread
      start_grammar_check_thread
    end
    puts "Nuovo documento creato."
  end

  def open_file
    check_unsaved_changes(:open)
  end

  def open_file_dialog
    dialog = Gtk::FileChooserDialog.new(title: 'Open File', parent: @root, action: :open)
    dialog.add_button('Cancel', Gtk::ResponseType::CANCEL); dialog.add_button('Open', Gtk::ResponseType::ACCEPT)
    filter = Gtk::FileFilter.new; filter.set_name('Text files');
    ['*.txt', '*.md', '*.rb', '*.py'].each { |p| filter.add_pattern(p) }
    dialog.add_filter(filter); dialog.add_filter(Gtk::FileFilter.new.tap { |f| f.set_name('All files'); f.add_pattern('*') })
    dialog.signal_connect('response') do |d, res|
      if res == Gtk::ResponseType::ACCEPT
        begin
          file = d.file
          if file&.path && File.exist?(file.path)
            content = File.read(file.path); visual_content = content.gsub("\n", "#{ENTER_SYMBOL}\n")
            @text.buffer.text = visual_content; apply_enter_symbol_tags_to_buffer
            @current_file_path = file.path
            update_window_title
            remove_all_error_tags # Pulisce errori del documento precedente
            # Se il controllo grammaticale è attivo, forza un nuovo controllo
            if @grammar_check_enabled
              stop_grammar_check_thread
              start_grammar_check_thread
            end
          else
            show_error_dialog("File non valido o non esistente.")
          end
        rescue => e
          show_error_dialog("Errore apertura file: #{e.message}")
        end
      end
      d.destroy
    end
    dialog.show
  end

  def save_file
    # Salvataggio rapido - usa il percorso corrente o chiedi dove salvare
    @current_file_path ? save_to_file(@current_file_path) : show_save_dialog
  end

  def save_as_file
    # Chiedi sempre dove salvare
    show_save_dialog
  end

 def select_font
    # Creazione di una finestra di dialogo personalizzata e più spaziosa
    dialog = Gtk::Dialog.new(title: 'Seleziona Font e Dimensione', parent: @root, flags: [:modal, :destroy_with_parent])
    dialog.set_default_size(450, 500)

    # Box verticale principale per organizzare i contenuti
    main_box = Gtk::Box.new(:vertical, 12)
    main_box.set_margin_top(10); main_box.set_margin_bottom(10)
    main_box.set_margin_start(10); main_box.set_margin_end(10)
    dialog.content_area.append(main_box)

    # 1. Area per l'elenco dei font
    scrolled_window = Gtk::ScrolledWindow.new
    scrolled_window.set_policy(:automatic, :automatic)
    scrolled_window.set_vexpand(true)
    list_box = Gtk::ListBox.new
    scrolled_window.set_child(list_box)
    main_box.append(scrolled_window)

    # 2. Area per l'anteprima e la selezione della dimensione
    preview_box = Gtk::Box.new(:horizontal, 10)
    main_box.append(preview_box)

    preview_label = Gtk::Label.new("Ma la volpe, col suo balzo, ha raggiunto il quieto Fido.")
    preview_label.set_hexpand(true)
    preview_label.set_halign(Gtk::Align::START)
    
    adjustment = Gtk::Adjustment.new(@current_font_size, 8, 72, 1, 10, 0)
    size_spin_button = Gtk::SpinButton.new(adjustment, 1.0, 0)

    preview_box.append(preview_label)
    preview_box.append(size_spin_button)

    # Popolamento e logica
    font_families = @text.pango_context.font_map.families.map(&:name)
    excluded_variants = / (Bold|Italic|Oblique|Condensed|Light|Heavy|Medium|Black|Regular)$/i
    filtered_fonts = font_families.reject { |name| name.match?(excluded_variants) }.uniq.sort

    # Funzione helper per aggiornare l'anteprima (con validazione)
    update_preview = lambda do
      selected_row = list_box.selected_row
      return unless selected_row
      
      font_name = selected_row.child.text
      font_size = size_spin_button.value.to_i
      
      begin
        # Sanifica il nome del font per evitare problemi CSS
        safe_font_name = font_name.gsub(/["'\\]/, '')
        
        provider = Gtk::CssProvider.new
        # Usa virgolette singole per evitare problemi con nomi di font contenenti virgolette doppie
        css_data = "label { font-family: '#{safe_font_name}'; font-size: #{font_size}pt; }"
        provider.load_from_data(css_data)
        
        # Rimuovi il provider precedente se esiste
        if @preview_font_provider
          preview_label.style_context.remove_provider(@preview_font_provider)
          @preview_font_provider = nil
        end
        
        # Salva il nuovo provider per poterlo rimuovere successivamente
        @preview_font_provider = provider
        
        preview_label.style_context.add_provider(provider, Gtk::StyleProvider::PRIORITY_USER)
      rescue StandardError => e
        puts "Errore nell'applicazione del font di anteprima: #{e.message}"
        # In caso di errore, usa un font di fallback
        provider = Gtk::CssProvider.new
        provider.load_from_data("label { font-family: 'monospace'; font-size: #{font_size}pt; }")
        preview_label.style_context.add_provider(provider, Gtk::StyleProvider::PRIORITY_USER)
      end
    end

    # Popola la lista e imposta la riga attualmente selezionata
    filtered_fonts.each do |font_name|
      row_label = Gtk::Label.new(font_name)
      row_label.set_halign(Gtk::Align::START)
      list_box.append(row_label)
      
      # Se questo è il font corrente, seleziona la riga
      if font_name == @current_font_family
        list_box.select_row(row_label.parent)
      end
    end

    # Connetti i segnali per l'interattività 
    list_box.signal_connect('row-selected') { update_preview.call }
    size_spin_button.signal_connect('value-changed') { update_preview.call }

    # Imposta lo stato iniziale dell'anteprima
    update_preview.call
    
    # Pulsanti e gestione della risposta
    dialog.add_button('Annulla', Gtk::ResponseType::CANCEL)
    dialog.add_button('OK', Gtk::ResponseType::ACCEPT)

    dialog.signal_connect('response') do |d, response_id|
      if response_id == Gtk::ResponseType::ACCEPT
        selected_row = list_box.selected_row
        if selected_row
          new_font_family = selected_row.child.text
          new_font_size = size_spin_button.value.to_i
          
          # Applica il font al TextView principale con gestione degli errori
          if apply_font_to_textview(new_font_family, new_font_size)
            @current_font_family = new_font_family
            @current_font_size = new_font_size
            update_window_title
          else
            show_error_dialog("Impossibile applicare il font selezionato. Ripristinato il font precedente.")
          end
        end
      end
      d.destroy
    end

    dialog.show
  end



 # Metodo separato per applicare il font al TextView principale
  def apply_font_to_textview(font_family, font_size)
    begin
      # Sanifica il nome del font
      safe_font_name = font_family.gsub(/["'\\]/, '')
      
      # Rimuovi il CSS provider precedente se esiste
      if @current_font_provider
        @text.style_context.remove_provider(@current_font_provider)
        @current_font_provider = nil
      end
      
      # Crea e applica il nuovo provider
      @current_font_provider = Gtk::CssProvider.new
      css_data = "textview { font-family: '#{safe_font_name}'; font-size: #{font_size}pt; }"
      @current_font_provider.load_from_data(css_data)
      @text.style_context.add_provider(@current_font_provider, Gtk::StyleProvider::PRIORITY_APPLICATION)
      
      return true
    rescue StandardError => e
      puts "Errore nell'applicazione del font: #{e.message}"
      
      # In caso di errore, ripristina un font sicuro
      begin
        @current_font_provider = Gtk::CssProvider.new if @current_font_provider.nil?
        fallback_css = "textview { font-family: 'monospace'; font-size: 12pt; }"
        @current_font_provider.load_from_data(fallback_css)
        @text.style_context.add_provider(@current_font_provider, Gtk::StyleProvider::PRIORITY_APPLICATION)
      rescue StandardError => fallback_error
        puts "Errore anche nel font di fallback: #{fallback_error.message}"
      end
      
      return false
    end
  end
 
  def process_selected_text_with_groq(ai_action)
    unless @ai_configured
      show_error_dialog(
        "Funzionalità AI non disponibile.\n\n" +
        "Per attivarla, inserisci una chiave API valida nel file 'config.yml' " +
        "e riavvia l'applicazione."
      )
      return # Interrompe l'esecuzione del metodo
    end

    buffer = @text.buffer
    unless buffer.has_selection?
      show_error_dialog('Seleziona del testo per processarlo con AI.')
      return
    end

    waiting_dialog = show_waiting_message("Elaborazione AI in corso...")

    Thread.new do
      begin
        # Ottieni il testo selezionato
        selection_bound, cursor_bound = buffer.selection_bounds
        selected_text = buffer.get_text(selection_bound, cursor_bound, false)

        prompt_prefix = get_prompt_prefix(ai_action)
        full_prompt = "#{prompt_prefix} #{selected_text}"
        
        groq_response_text = generate_content_with_groq(full_prompt)
        
        # Aggiorna l'interfaccia nel thread principale
        GLib::Idle.add do
          waiting_dialog.destroy
          show_scrollable_message("Risultato AI", groq_response_text)
          false # Esegui solo una volta
        end
      rescue StandardError => e
        GLib::Idle.add do
          waiting_dialog.destroy if waiting_dialog
          show_error_dialog("Errore durante l'elaborazione AI: #{e.message}")
          false # Esegui solo una volta
        end
      end
    end
  end
 
  def start_languagetool_server
    puts "Avvio del server LanguageTool..."
    # command = "java -Xmx2G -Xms512M -XX:+UseG1GC -cp '/usr/share/languagetool/*' org.languagetool.server.HTTPServer --port 8081"
    command = "java -Xmx2G -Xms512M -XX:+UseG1GC -cp '#{LANGUAGETOOL_PATH}/*' " +
              "org.languagetool.server.HTTPServer --port #{@languagetool_port}"

    stdin, stdout, stderr, wait_thr = Open3.popen3(command)

    Thread.new do
      stdout.each { |line| puts "LT: #{line}" }
    end

    Thread.new do
      stderr.each { |line| puts "LT ERR: #{line}" }
    end

    wait_thr
  end

  def stop_languagetool_server
    return unless @languagetool_process

    begin
      puts "Arresto del server LanguageTool..."
      Process.kill("TERM", @languagetool_process.pid)
      @languagetool_process = nil
    rescue StandardError => e
      puts "Errore nell'arresto del server: #{e.message}"
      # Imposta comunque a nil per evitare tentativi futuri
      @languagetool_process = nil
    end
  end
  
  def start_grammar_check_thread
    return if @grammar_check_thread && @grammar_check_thread.alive?
    
    puts "Avvio thread controllo grammaticale ottimizzato..."
    
    @grammar_check_thread = Thread.new do
      loop do
        break unless @grammar_check_enabled
        
        begin
          # Verifica prima se c'è del testo nel documento
          buffer = @text.buffer
          total_text = buffer.get_text(buffer.start_iter, buffer.end_iter, false)
          clean_total_text = total_text.gsub(ENTER_SYMBOL, "").strip
          
          # Se il documento è vuoto o contiene solo spazi, salta il controllo
          if clean_total_text.empty?
            puts "Documento vuoto, salto il controllo grammaticale"
            sleep(2)
            next
          end
          
          # Ottieni solo il testo visibile più la tolleranza
          visible_text_info = get_visible_text_with_tolerance
          
          # Doppio controllo: anche il testo visibile deve avere contenuto
          next if visible_text_info[:text].strip.empty?
          
          # Controlla la grammatica solo per il testo visibile
          errors = @grammar_checker.check_text(visible_text_info[:text])
          
          # Aggiorna l'interfaccia nel thread principale
          GLib::Idle.add do
            update_grammar_errors_for_visible_area(errors, visible_text_info)
            false
          end
          
          # Attendi prima del prossimo controllo
          sleep(2)
          
        rescue StandardError => e
          puts "Errore nel controllo grammaticale: #{e.message}"
          sleep(5) # Attendi di più in caso di errore
        end
      end
      
      puts "Thread controllo grammaticale terminato"
    end
  end
 
  def stop_grammar_check_thread
    # Salva il riferimento al thread corrente in una variabile locale
    thread_to_stop = @grammar_check_thread

    # Non fare nulla se non c'è un thread attivo
    return unless thread_to_stop && thread_to_stop.alive?

    puts "Richiesta di arresto per il thread di controllo grammaticale..."

    # Segnala al thread di terminare il suo ciclo
    @grammar_check_enabled = false
    
    # Imposta la variabile di istanza a nil ORA, per evitare che 
    # nuove operazioni vengano avviate su un thread che sta per essere chiuso.
    @grammar_check_thread = nil

    # Avvia un nuovo thread "osservatore" per gestire la terminazione in modo pulito
    # senza bloccare l'interfaccia utente.
    Thread.new do
      # Usa la variabile locale per attendere la fine del thread.
      # Il metodo .join attenderà che il loop interno del thread si concluda 
      # non appena rileverà che @grammar_check_enabled è false.
      finished = thread_to_stop.join(5) # Attendi al massimo 5 secondi

      if finished
        puts "Thread controllo grammaticale terminato correttamente."
      else
        # Se il thread non si è fermato entro il timeout (caso anomalo),
        # allora, come ultima risorsa, forziamo la chiusura.
        puts "Timeout raggiunto. Forzo l'arresto del thread controllo grammaticale."
        thread_to_stop.kill
      end

      # La pulizia dell'interfaccia utente DEVE sempre avvenire nel thread principale.
      GLib::Idle.add do
        puts "Eseguo la pulizia dei tag di errore dall'interfaccia."
        remove_all_error_tags
        false # Assicura che questo blocco venga eseguito una sola volta.
      end
    end
  end
 
  def setup_mouse_motion_controller
    # Inizializza le variabili per il sistema di tooltip
    @grammar_tooltip = nil
    @current_error_tag = nil
    @tooltip_timeout_id = nil
    
    # Controller per il movimento del mouse
    motion_controller = Gtk::EventControllerMotion.new
    
    motion_controller.signal_connect('motion') do |controller, x, y|
      handle_mouse_motion(x, y)
    end
    
    motion_controller.signal_connect('leave') do |controller|
      hide_grammar_tooltip
    end
    
    @text.add_controller(motion_controller)
  end
 
  def handle_mouse_motion(x, y)
    return unless @grammar_check_enabled
    
    # Converti le coordinate del mouse in posizione del testo
    buffer_x, buffer_y = @text.window_to_buffer_coords(Gtk::TextWindowType::WIDGET, x.to_i, y.to_i)
    iter, trailing = @text.get_iter_at_location(buffer_x, buffer_y)
    
    return unless iter
    
    # Cerca se c'è un tag di errore grammaticale alla posizione del cursore
    error_tag_name = find_grammar_error_at_position(iter.offset)
    
    if error_tag_name
      # Se siamo sopra un errore diverso da quello corrente, aggiorna il tooltip
      if error_tag_name != @current_error_tag
        @current_error_tag = error_tag_name
        show_grammar_tooltip_delayed(x, y, error_tag_name)
      end
    else
      # Se non siamo sopra nessun errore, nascondi il tooltip
      if @current_error_tag
        @current_error_tag = nil
        hide_grammar_tooltip
      end
    end
  end
 
  private

  def update_window_title
    base_title = "Text Editor by blastbeat"
    file_part = @current_file_path ? " - #{File.basename(@current_file_path)}" : " - [Untitled]"
    font_part = " - [#{@current_font_family}]"
    ai_part = @ai_configured ? " - [AI: #{@groq_model}]" : ""
    @root.set_title("#{base_title}#{file_part}#{font_part}#{ai_part}")
  end

  def play_key_press_sound(keyval)
    return unless @sound_enabled
    return if @nosound_keys.include?(keyval)
    @sound_player.play_sound
  end

  # Metodo unificato per salvare su file
  # @param file_path [String] Percorso del file
  # @param is_autosave [Boolean] True se è un autosave, false per save normale
  # @return [Boolean] True se il salvataggio è riuscito
  def save_to_file(file_path, is_autosave: false)
    begin
      # Ottieni il contenuto pulito dal buffer
      content = get_clean_buffer_content
      
      # Determina il percorso finale
      final_path = is_autosave ? generate_autosave_path(file_path) : file_path
      
      # Scrivi il file
      File.write(final_path, content)
      
      # Aggiorna il percorso corrente solo per save normali
      @current_file_path = file_path unless is_autosave
      
      # Mostra notifica appropriata
      show_save_notification(final_path, is_autosave: is_autosave)
      
      # Log
      puts "#{is_autosave ? 'Autosave' : 'File saved'}: #{final_path}"
      
      return true
    rescue StandardError => e
      error_msg = "Errore #{is_autosave ? 'autosave' : 'salvataggio'}: #{e.message}"
      puts "#{error_msg}"
      show_error_dialog(error_msg) unless is_autosave
      return false
    end
  end
  
  # Estrae il contenuto pulito dal buffer (rimuove simboli ENTER)
  # @return [String] Contenuto pulito
  def get_clean_buffer_content
    buffer = @text.buffer
    content_with_symbols = buffer.get_text(buffer.start_iter, buffer.end_iter, false)
    content_with_symbols.gsub(ENTER_SYMBOL, "")
  end
  
  # Genera il percorso per un file di autosave
  # @param original_path [String] Percorso del file originale
  # @return [String] Percorso del file di autosave con timestamp
  def generate_autosave_path(original_path)
    timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
    dir = File.dirname(original_path)
    basename = File.basename(original_path, '.*')
    ext = File.extname(original_path)
    File.join(dir, "#{basename}_autosave_#{timestamp}#{ext}")
  end
  
  def start_autosave
    return if @autosave_timeout_id # Se già attivo, non riavviarlo
    return unless @autosave_enabled
    
    @autosave_timeout_id = GLib::Timeout.add_seconds(AUTOSAVE_INTERVAL) do
      perform_autosave if @autosave_enabled
      true # Continua il timeout
    end
    
    puts "Autosave avviato (intervallo: #{AUTOSAVE_INTERVAL} secondi)"
  end

  def stop_autosave
    if @autosave_timeout_id
      GLib::Source.remove(@autosave_timeout_id)
      @autosave_timeout_id = nil
      puts "Autosave arrestato"
    end
  end

  def show_save_notification(file_path, is_autosave: false, duration: 3)
    original_title = @root.title
    
    # Testo della notifica
    prefix = is_autosave ? "AUTOSAVE" : "MEMORIZZATO DOCUMENTO"
    notification_title = "#{prefix}: #{File.basename(file_path)} - #{original_title}"
    
    # Mostra notifica
    @root.set_title(notification_title)
    
    # Ripristina il titolo dopo la durata specificata
    GLib::Timeout.add_seconds(duration) do
      update_window_title
      false  # Esegui solo una volta
    end
  end

  def perform_autosave
    # Verifica se c'è un file da salvare
    unless @current_file_path && !@current_file_path.empty?
      puts "Autosave saltato: nessun file aperto/salvato"
      return
    end
    
    # Usa il metodo unificato con flag autosave
    save_to_file(@current_file_path, is_autosave: true)
  end  
  
  def cleanup_autosave_files(keep_last: 3)
    return 0 unless @current_file_path
    
    begin
      dir = File.dirname(@current_file_path)
      basename = File.basename(@current_file_path, '.*')
      ext = File.extname(@current_file_path)
      
      pattern = File.join(dir, "#{basename}_autosave_*#{ext}")
      autosave_files = Dir.glob(pattern).sort.reverse
      
      return 0 if autosave_files.empty?
      
      files_to_delete = autosave_files[keep_last..-1] || []
      deleted_count = 0
      
      files_to_delete.each do |file|
        File.delete(file)
        deleted_count += 1
        puts "Autosave vecchio rimosso: #{File.basename(file)}"
      end
      
      kept_count = [autosave_files.length, keep_last].min
      puts "Cleanup autosave completato (mantenuti #{kept_count} file, rimossi #{deleted_count})"
      return deleted_count
      
    rescue StandardError => e
      puts "Errore durante cleanup autosave: #{e.message}"
      return 0
    end
  end

  def cleanup_autosaves_with_confirmation
    unless @current_file_path
      show_info_dialog("Nessun file aperto. Non ci sono autosave da cancellare.")
      return
    end
    
    # Conta i file di autosave esistenti
    dir = File.dirname(@current_file_path)
    basename = File.basename(@current_file_path, '.*')
    ext = File.extname(@current_file_path)
    pattern = File.join(dir, "#{basename}_autosave_*#{ext}")
    autosave_files = Dir.glob(pattern)
    
    if autosave_files.empty?
      show_info_dialog("Non ci sono file di autosave da cancellare per:\n\n#{File.basename(@current_file_path)}")
      return
    end
    
    # Chiedi conferma con il nome del file
    current_filename = File.basename(@current_file_path)
    dialog = Gtk::MessageDialog.new(
      parent: @root,
      flags: :modal,
      type: :question,
      buttons: :yes_no,
      message: "File corrente: #{current_filename}\n\nTrovati #{autosave_files.length} file di autosave.\n\nVuoi cancellarli mantenendo solo gli ultimi 2?"
    )
    
    dialog.signal_connect('response') do |d, res|
      if res == Gtk::ResponseType::YES
        deleted_count = cleanup_autosave_files(keep_last: 2)
        show_info_dialog("Operazione completata per:\n#{current_filename}\n\nFile rimossi: #{deleted_count}\nFile mantenuti: #{[autosave_files.length - deleted_count, 0].max}")
      end
      d.destroy
    end
    
    dialog.show
  end

  # METODO PER MOSTRARE DIALOGHI INFORMATIVI:
  def show_info_dialog(message)
    dialog = Gtk::MessageDialog.new(
      parent: @root,
      flags: :modal,
      type: :info,
      buttons: :ok,
      message: message
    )
    dialog.signal_connect('response') { |d, r| d.destroy }
    dialog.show
  end

  def apply_enter_symbol_tags_to_buffer
    buffer = @text.buffer; start_iter = buffer.start_iter
    loop do
      match_start, match_end = start_iter.forward_search(ENTER_SYMBOL, :text_only, nil)
      break unless match_start
      buffer.apply_tag(@enter_symbol_tag, match_start, match_end); start_iter = match_end
    end
  end

  def show_error_dialog(message)
    dialog = Gtk::MessageDialog.new(parent: @root, flags: :modal, type: :error, buttons: :ok, message: message)
    dialog.signal_connect('response') { |d, r| d.destroy }; dialog.show
  end
  
  def show_replacement_notification_popover(message)
    # Riproduci il suono di notifica se abilitato
    @notification_sound.play_sound if @sound_enabled

    # IMPORTANTE: Distruggi completamente il popover precedente
    if @replacement_popover
      begin
        @replacement_popover.unparent  # Rimuovi dal parent
        @replacement_popover = nil
      rescue StandardError => e
        puts "Errore nella rimozione del popover precedente: #{e.message}"
        @replacement_popover = nil
      end
    end

    # Cancella eventuali timeout pendenti
    if @replacement_timeout_id
      GLib::Source.remove(@replacement_timeout_id)
      @replacement_timeout_id = nil
    end

    begin
      # Ottieni la posizione del cursore
      buffer = @text.buffer
      cursor_iter = buffer.get_iter_at(offset: buffer.cursor_position)
      
      # Converti le coordinate del buffer in coordinate della finestra
      cursor_rect_buffer = @text.get_iter_location(cursor_iter)
      window_x, window_y = @text.buffer_to_window_coords(
        Gtk::TextWindowType::WIDGET, 
        cursor_rect_buffer.x, 
        cursor_rect_buffer.y
      )

      # Crea un NUOVO Popover
      @replacement_popover = Gtk::Popover.new
      @replacement_popover.set_parent(@text)
      @replacement_popover.set_position(Gtk::PositionType::TOP)
      @replacement_popover.set_autohide(false)
      @replacement_popover.set_has_arrow(false)
      
      # Crea il contenuto del popover
      box = Gtk::Box.new(Gtk::Orientation::HORIZONTAL, 0)
      box.set_margin_top(3)
      box.set_margin_bottom(3)
      box.set_margin_start(6)
      box.set_margin_end(6)
      
      label = Gtk::Label.new(message)
      
      # CSS 
      css_provider = Gtk::CssProvider.new
      css_data = <<~CSS
        popover {
          background-color: #f8f9fa;
          border: 1px solid #007bff;
        }
        label.notification {
          color: #007bff;
          font-weight: bold;
          font-size: 9pt; 
        }
      CSS
      css_provider.load_from_data(css_data)
      
      label.add_css_class('notification')
      label.style_context.add_provider(css_provider, Gtk::StyleProvider::PRIORITY_APPLICATION)
      @replacement_popover.style_context.add_provider(css_provider, Gtk::StyleProvider::PRIORITY_APPLICATION)
      
      box.append(label)
      @replacement_popover.set_child(box)
      
      # Crea il Gdk::Rectangle
      gdk_rect = Gdk::Rectangle.new(
        window_x + 70, 
        window_y - 20, 
        1, 
        cursor_rect_buffer.height
      )
      
      @replacement_popover.set_pointing_to(gdk_rect)
      @replacement_popover.popup
      
      # Programma la chiusura automatica con cleanup completo
      @replacement_timeout_id = GLib::Timeout.add_seconds(1) do
        begin
          if @replacement_popover
            @replacement_popover.unparent  # IMPORTANTE: usa unparent invece di popdown
            @replacement_popover = nil
          end
        rescue StandardError => e
          puts "Errore nella chiusura del popover: #{e.message}"
          @replacement_popover = nil
        end
        @replacement_timeout_id = nil
        false  # Rimuovi il timeout
      end
      
    rescue StandardError => e
      puts "Errore in show_replacement_notification_popover: #{e.message}"
      # Cleanup in caso di errore
      if @replacement_popover
        begin
          @replacement_popover.unparent
        rescue
          # Ignora errori durante il cleanup
        end
        @replacement_popover = nil
      end
    end
  end

  def generate_content_with_groq(prompt)
    unless @groq_api_key && !@groq_api_key.empty?
      return "Errore: La chiave API Groq non è impostata."
    end

    response = HTTPX.post(@groq_api_url, 
      headers: {
        "Authorization" => "Bearer #{@groq_api_key}",
        "Content-Type" => "application/json"
      },
      json: {
        "model" => @groq_model,
        "messages" => [
          {
            "role" => "system",
            "content" => "Sei un assistente esperto in lingua italiana. Rispondi in modo chiaro e conciso, SENZA usare formattazione Markdown."
          },
          {
            "role" => "user",
            "content" => prompt
          }
        ],
        "temperature" => 0.7
      }
    )
   case response.status
     when 200
      data = JSON.parse(response.body)
      text = data.dig("choices", 0, "message", "content") || "Risposta vuota dall'AI."
      return text.gsub('*', '') # Rimuove eventuali asterischi di formattazione
  # ⭐ MODIFICATO - Ora mostra anche il body dell'errore
     when 400 then "Errore 400: Richiesta non valida. Controlla il formato.\n\nDettagli: #{response.body}"
     when 401 then "Errore 401: API Key non valida o mancante."
     when 403 then "Errore 403: Accesso negato. Verifica i permessi della API Key."
     when 404 then "Errore 404: Modello o endpoint non trovato."
     when 429 then "Errore 429: Troppe richieste. Attendi prima di riprovare."
     when 500 then "Errore 500: Problema interno ai server di xAI."
       else "Errore #{response.status}: #{response.body}"
     end
    # ⭐ MODIFICATO - Mostra anche il backtrace in caso di eccezione
     rescue StandardError => e
      "Errore durante la richiesta API: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
  end
  
  def get_prompt_prefix(ai_action)
    case ai_action
    when 'sinonimo'
      "Trova un elenco di sinonimi per la seguente parola/frase, anche in base al contesto:"
    when 'migliora testo'
      "Migliora la seguente parte di testo rendendola più chiara e scorrevole:"
    when 'riscrivi testo'
      "Riscrivi il seguente testo in modo diverso, mantenendo lo stesso significato:"
    when 'arrichisci testo'
      "Arricchisci il seguente testo aggiungendo dettagli e rendendolo più descrittivo:"
    else
      "Processa il seguente testo:"
    end
  end

  def show_waiting_message(message)
    dialog = Gtk::MessageDialog.new(parent: @root, flags: :modal, type: :info, message: message)
    dialog.set_title("Attendere...")
    dialog.show
    dialog
  end

  def show_scrollable_message(title, message)
    dialog = Gtk::Window.new
    dialog.set_title(title)
    dialog.set_default_size(600, 400)
    dialog.set_transient_for(@root)
    dialog.set_modal(true)

    main_box = Gtk::Box.new(:vertical, 10)
    main_box.set_margin_top(10); main_box.set_margin_bottom(10)
    main_box.set_margin_start(10); main_box.set_margin_end(10)
    dialog.set_child(main_box)
    
    scrolled_window = Gtk::ScrolledWindow.new
    scrolled_window.set_policy(:automatic, :automatic)
    scrolled_window.set_vexpand(true)
    
    text_view = Gtk::TextView.new
    text_view.set_editable(false)
    text_view.set_wrap_mode(:word)
    text_view.buffer.set_text(message)
    scrolled_window.set_child(text_view)
                
     # Applica un font più grande alla TextView
    css_provider = Gtk::CssProvider.new
    css_data = "textview { font-family: 'prototype'; font-size: 13pt; }"
    css_provider.load_from_data(css_data)
    text_view.style_context.add_provider(css_provider, Gtk::StyleProvider::PRIORITY_APPLICATION)
    
    scrolled_window.set_child(text_view)
        
    main_box.append(scrolled_window)

    button = Gtk::Button.new(label: 'Chiudi')
    button.signal_connect('clicked') { dialog.destroy }
    main_box.append(button)
    
    dialog.show
  end
    
  def get_visible_text_with_tolerance(tolerance_lines = 10)
    buffer = @text.buffer
    
    # Ottieni l'area visibile della TextView
    visible_rect = @text.visible_rect
    
    # Converti le coordinate visibili in iteratori di testo
    top_iter, _ = @text.get_line_at_y(visible_rect.y)
    bottom_iter, _ = @text.get_line_at_y(visible_rect.y + visible_rect.height)
    
    # Calcola le righe di inizio e fine con tolleranza
    start_line = [top_iter.line - tolerance_lines, 0].max
    end_line = [bottom_iter.line + tolerance_lines, buffer.line_count - 1].min
    
    # Ottieni gli iteratori per le righe con tolleranza
    start_iter = buffer.get_iter_at(:line => start_line)
    end_iter = buffer.get_iter_at(:line => end_line)
    end_iter.forward_to_line_end
    
    # Estrai il testo
    original_text = buffer.get_text(start_iter, end_iter, false)
    clean_text = original_text.gsub(ENTER_SYMBOL, "\n")
    
    {
      text: clean_text,
      original_text: original_text,
      start_offset: start_iter.offset,
      end_offset: end_iter.offset,
      start_line: start_line,
      end_line: end_line
    }
  end

  def update_grammar_errors_for_visible_area(errors, visible_text_info)
    return unless @grammar_check_enabled
    
    buffer = @text.buffer
    
    # Rimuovi solo i tag di errore nell'area visibile
    remove_error_tags_in_range(visible_text_info[:start_offset], visible_text_info[:end_offset])
    
    return if errors.empty?
    
    errors.each_with_index do |error, index|
      begin
        # Calcola la posizione assoluta nell'intero documento
        relative_position = error[:position]
        absolute_position = visible_text_info[:start_offset] + 
                            calculate_adjusted_position_in_range(
                              relative_position, 
                              visible_text_info[:original_text], 
                              visible_text_info[:text]
                            )
        
        adjusted_length = error[:length]
        
        # Controlla che la posizione sia valida nell'intero documento
        total_text_length = buffer.get_text(buffer.start_iter, buffer.end_iter, false).length
        next if absolute_position < 0 || absolute_position >= total_text_length
        
        # Crea un tag unico per questo errore (include l'offset per evitare duplicati)
        tag_name = "grammar_error_#{absolute_position}_#{index}"
        error_tag = buffer.tag_table.lookup(tag_name)
        
        unless error_tag
          error_tag = Gtk::TextTag.new(tag_name)
          error_tag.underline = Pango::Underline::ERROR
          error_tag.underline_rgba = Gdk::RGBA.new(1.0, 0.0, 0.0, 1.0) # Rosso
          error_tag.foreground_rgba = Gdk::RGBA.new(1.0, 0.0, 0.0, 1.0) # Testo rosso
          buffer.tag_table.add(error_tag)
        end
        
        # Applica il tag
        start_iter = buffer.get_iter_at(offset: absolute_position)
        end_iter = buffer.get_iter_at(offset: [absolute_position + adjusted_length, total_text_length].min)
        
        buffer.apply_tag(error_tag, start_iter, end_iter)
        
        # Salva i dati dell'errore per riferimenti futuri
        @error_tags[tag_name] = {
          error: error,
          start_offset: absolute_position,
          end_offset: absolute_position + adjusted_length
        }
        
      rescue StandardError => e
        puts "Errore nell'applicazione del tag di errore: #{e.message}"
      end
    end
    
    #puts "Controllate righe #{visible_text_info[:start_line]}-#{visible_text_info[:end_line]}, trovati #{errors.length} errori"
  end

  def remove_error_tags_in_range(start_offset, end_offset)
    return if @error_tags.empty? # Non fare nulla se non ci sono tag da rimuovere

    buffer = @text.buffer
    
    # Trova e rimuovi solo i tag nell'intervallo specificato
    tags_to_remove = []
    
    @error_tags.each do |tag_name, data|
      # Se l'errore è completamente o parzialmente nell'intervallo, rimuovilo
      if (data[:start_offset] >= start_offset && data[:start_offset] <= end_offset) ||
         (data[:end_offset] >= start_offset && data[:end_offset] <= end_offset) ||
         (data[:start_offset] <= start_offset && data[:end_offset] >= end_offset)
        
        tags_to_remove << tag_name
      end
    end
    
    tags_to_remove.each do |tag_name|
      tag = buffer.tag_table.lookup(tag_name)
      if tag
        buffer.remove_tag(tag, buffer.start_iter, buffer.end_iter)
        buffer.tag_table.remove(tag)
      end
      @error_tags.delete(tag_name)
    end
  end

  def calculate_adjusted_position_in_range(clean_position, original_text, clean_text)
    # Conta quanti simboli ENTER_SYMBOL ci sono prima della posizione nel testo pulito
    # ma solo all'interno del range considerato
    enter_symbols_before = 0
    clean_char_count = 0
    i = 0
    
    while i < original_text.length && clean_char_count <= clean_position
      if i + ENTER_SYMBOL.length <= original_text.length && 
         original_text[i, ENTER_SYMBOL.length] == ENTER_SYMBOL
        enter_symbols_before += 1
        i += ENTER_SYMBOL.length
      else
        clean_char_count += 1
        i += 1
      end
    end
    
    # La posizione aggiustata include i simboli ENTER_SYMBOL incontrati
    return clean_position + (enter_symbols_before * (ENTER_SYMBOL.length - 1))
  end
 
  def remove_all_error_tags
    buffer = @text.buffer
    
    @error_tags.each do |tag_name, _data|
      tag = buffer.tag_table.lookup(tag_name)
      if tag
        buffer.remove_tag(tag, buffer.start_iter, buffer.end_iter)
        buffer.tag_table.remove(tag)
      end
    end
    
    @error_tags.clear
    puts "Rimossi tutti i tag di errore grammaticale"
  end
  
  def find_grammar_error_at_position(offset)
    @error_tags.each do |tag_name, data|
      if offset >= data[:start_offset] && offset < data[:end_offset]
        return tag_name
      end
    end
    nil
  end

  def show_grammar_tooltip_delayed(x, y, error_tag_name)
    # Cancella il timeout precedente se esiste
    if @tooltip_timeout_id
      GLib::Source.remove(@tooltip_timeout_id)
      @tooltip_timeout_id = nil
    end
    
    # Nascondi il tooltip corrente se esiste (con cleanup completo)
    hide_grammar_tooltip
    
    # Mostra il nuovo tooltip dopo un breve ritardo
    @tooltip_timeout_id = GLib::Timeout.add(500) do # 500ms di ritardo
      show_grammar_tooltip(x, y, error_tag_name)
      @tooltip_timeout_id = nil
      false # Rimuovi il timeout
    end
  end

  def show_grammar_tooltip(x, y, error_tag_name)
    return unless @error_tags[error_tag_name]
    
    error_data = @error_tags[error_tag_name]
    error = error_data[:error]
    
    # IMPORTANTE: Nascondi e distruggi il tooltip precedente completamente
    hide_grammar_tooltip
    
    begin
      # Crea il popover per il tooltip
      @grammar_tooltip = Gtk::Popover.new
      @grammar_tooltip.set_parent(@text)
      @grammar_tooltip.set_autohide(false)
      @grammar_tooltip.set_has_arrow(true)
      
      # Crea il contenuto del tooltip
      main_box = Gtk::Box.new(Gtk::Orientation::VERTICAL, 8)
      main_box.set_margin_top(8)
      main_box.set_margin_bottom(8)
      main_box.set_margin_start(10)
      main_box.set_margin_end(10)
      
      # Titolo con il messaggio di errore
      error_label = Gtk::Label.new(error[:message])
      error_label.set_wrap(true)
      error_label.set_max_width_chars(50)
      error_label.set_justify(Gtk::Justification::LEFT)
      
      # Testo dell'errore evidenziato
      error_text_label = nil
      if error[:error_text] && !error[:error_text].empty?
        error_text_label = Gtk::Label.new("Testo: \"#{error[:error_text]}\"")
        error_text_label.set_wrap(true)
        error_text_label.set_max_width_chars(50)
      end
      
      # Suggerimenti
      suggestions_box = nil
      if error[:suggestions] && !error[:suggestions].empty?
        suggestions_label = Gtk::Label.new("Suggerimenti:")
        suggestions_label.set_markup("<b>Suggerimenti:</b>")
        
        suggestions_box = Gtk::Box.new(Gtk::Orientation::VERTICAL, 4)
        suggestions_box.append(suggestions_label)
        
        error[:suggestions].first(5).each do |suggestion| # Limita a 5 suggerimenti
          suggestion_label = Gtk::Label.new("• #{suggestion}")
          suggestion_label.set_justify(Gtk::Justification::LEFT)
          suggestion_label.set_halign(Gtk::Align::START)
          suggestions_box.append(suggestion_label)
        end
      end
      
      # Aggiungi gli elementi al box principale
      main_box.append(error_label)
      main_box.append(error_text_label) if error_text_label
      main_box.append(suggestions_box) if suggestions_box
      
      # Applica lo stile CSS
      css_provider = Gtk::CssProvider.new
      css_data = <<~CSS
        popover {
          background-color: #ffffff;
          border: 1px solid #007bff;
          border-radius: 8px;
        }
        label.grammar-error {
          color: #dc3545;
          font-weight: bold;
          font-size: 10pt;
        }
        label.grammar-suggestion {
          color: #007bff;
          font-size: 9pt;
        }
        label.grammar-text {
          color: #6c757d;
          font-style: italic;
          font-size: 9pt;
        }
      CSS
      css_provider.load_from_data(css_data)
      
      # Applica le classi CSS
      error_label.add_css_class('grammar-error')
      error_label.style_context.add_provider(css_provider, Gtk::StyleProvider::PRIORITY_APPLICATION)
      
      if error_text_label
        error_text_label.add_css_class('grammar-text')
        error_text_label.style_context.add_provider(css_provider, Gtk::StyleProvider::PRIORITY_APPLICATION)
      end
      
      if suggestions_box
        suggestions_box.children.each do |child|
          if child.is_a?(Gtk::Label) && child.text.start_with?('•')
            child.add_css_class('grammar-suggestion')
            child.style_context.add_provider(css_provider, Gtk::StyleProvider::PRIORITY_APPLICATION)
          end
        end
      end
      
      @grammar_tooltip.style_context.add_provider(css_provider, Gtk::StyleProvider::PRIORITY_APPLICATION)
      @grammar_tooltip.set_child(main_box)
      
      # Posizionamento intelligente del tooltip
      text_allocation = @text.allocation
      text_height = text_allocation.height
      text_width = text_allocation.width
      
      # Determina la posizione migliore per il tooltip
      position = Gtk::PositionType::BOTTOM
      tooltip_y_offset = 20
      
      if y < 80
        position = Gtk::PositionType::BOTTOM
        tooltip_y_offset = 20
      elsif y > (text_height - 100)
        position = Gtk::PositionType::TOP
        tooltip_y_offset = -20
      else
        space_below = text_height - y
        space_above = y
        
        if space_below > space_above
          position = Gtk::PositionType::BOTTOM
          tooltip_y_offset = 20
        else
          position = Gtk::PositionType::TOP
          tooltip_y_offset = -20
        end
      end
      
      @grammar_tooltip.set_position(position)
      
      # Gestisci il posizionamento orizzontale
      tooltip_x = x.to_i
      if tooltip_x > (text_width - 250)
        tooltip_x = text_width - 250
      elsif tooltip_x < 20
        tooltip_x = 20
      end
      
      # Crea un rettangolo per il puntamento
      pointing_rect = Gdk::Rectangle.new(tooltip_x, y.to_i + tooltip_y_offset, 1, 1)
      @grammar_tooltip.set_pointing_to(pointing_rect)
      
      # Mostra il tooltip
      @grammar_tooltip.popup
      
    rescue StandardError => e
      puts "Errore nella creazione del tooltip grammaticale: #{e.message}"
      # Cleanup completo in caso di errore
      if @grammar_tooltip
        begin
          @grammar_tooltip.unparent
        rescue
          # Ignora errori durante il cleanup
        end
        @grammar_tooltip = nil
      end
    end
  end

  def hide_grammar_tooltip
    # Cancella il timeout se esiste
    if @tooltip_timeout_id
      GLib::Source.remove(@tooltip_timeout_id)
      @tooltip_timeout_id = nil
    end
    
    # IMPORTANTE: Distruggi completamente il tooltip usando unparent
    if @grammar_tooltip
      begin
        @grammar_tooltip.unparent  # Rilascia tutte le risorse
        @grammar_tooltip = nil
      rescue StandardError => e
        puts "Errore nella chiusura del tooltip grammaticale: #{e.message}"
        @grammar_tooltip = nil
      end
    end
  end
  
  def get_current_word
    buffer = @text.buffer
    cursor = buffer.get_iter_at(offset: buffer.cursor_position)

    # Trova l'inizio della parola andando INDIETRO
    start_iter = cursor.dup
    return "" unless start_iter.backward_word_start

    # La fine è la posizione CORRENTE del cursore
    end_iter = cursor.dup  # ← Usa la posizione del cursore!

    buffer.get_text(start_iter, end_iter, false)
  end
  
  def handle_word_completion
    # Non bloccare completamente, evita solo ricorsione
    return if @word_completion_active # ← Evita loop infiniti

    word = get_current_word
    return if word.length < 3

    words = extract_words_from_buffer
    suggestions = words.select { |w| w.start_with?(word) && w != word }
                       .sort              # ← Ordina alfabeticamente
                       .take(8)           # ← Limita subito

    if suggestions.empty?
      hide_word_completion
    else
      show_word_completion_popover(suggestions, word)
    end
  end

  def extract_words_from_buffer
    buffer = @text.buffer
    text = buffer.get_text(buffer.start_iter, buffer.end_iter, false)
    text.gsub(ENTER_SYMBOL, "")
        .scan(/\b[[:alpha:]]{3,}\b/)
        .uniq
  end
  
  def show_word_completion_popover(suggestions, current_word)
    if @completion_timeout_id
     GLib::Source.remove(@completion_timeout_id)
     @completion_timeout_id = nil
    end
 
    hide_word_completion

    @word_completion_popover = Gtk::Popover.new
    @word_completion_popover.set_parent(@text)
    @word_completion_popover.set_position(Gtk::PositionType::BOTTOM)
    @word_completion_popover.set_autohide(false)  # ← AGGIUNTO!
    @word_completion_popover.set_has_arrow(false)

    vbox = Gtk::Box.new(:vertical, 2)
    vbox.set_margin_top(4)      # ← Margini per estetica
    vbox.set_margin_bottom(4)
    vbox.set_margin_start(6)
    vbox.set_margin_end(6)
  
    @word_completion_listbox = Gtk::ListBox.new
    @word_completion_listbox.set_selection_mode(:single)

    suggestions.each do |s|  # ← .take(8) già fatto prima
      row = Gtk::Label.new(s)
      row.set_halign(:start)
      row.set_margin_top(3)
      row.set_margin_bottom(3)
      row.set_margin_start(6)   # ← Margini laterali
      row.set_margin_end(6)
      @word_completion_listbox.append(row)
    end

    # ✅ SELEZIONA LA PRIMA RIGA AUTOMATICAMENTE
    first_row = @word_completion_listbox.get_row_at_index(0)
    @word_completion_listbox.select_row(first_row) if first_row

    @word_completion_listbox.signal_connect("row-activated") do |lb, row|
      apply_completion(row.child.text, current_word)
      hide_word_completion
    end

    vbox.append(@word_completion_listbox)
    @word_completion_popover.set_child(vbox)

    # Posizionamento corretto vicino al cursore
    buffer = @text.buffer
    cursor_iter = buffer.get_iter_at(offset: buffer.cursor_position)

    # Ottieni il rettangolo del cursore nel sistema di coordinate del buffer
    cursor_rect = @text.get_iter_location(cursor_iter)

    # Converti in coordinate della finestra
    window_x, window_y = @text.buffer_to_window_coords(
    Gtk::TextWindowType::TEXT,  # ✅ Sistema di coordinate del TESTO
    cursor_rect.x, 
    cursor_rect.y
    )

    # Aggiungi offset per posizionare il popover:
    # - Leggermente a destra (+20px)
    # - Leggermente sotto la riga corrente (+25px)
    pointing_rect = Gdk::Rectangle.new(
    window_x + 50,          # ✅ Spostato a destra
    window_y + 25,          # ✅ Sotto il cursore
    1,                       # Larghezza minima
    1                        # Altezza minima
    )

    @word_completion_popover.set_pointing_to(pointing_rect)

    @word_completion_popover.popup
    @word_completion_active = true
  
    @completion_timeout_id = GLib::Timeout.add_seconds(8) do
      puts "Timeout per completamento parola raggiunto. Chiudo." # Messaggio di debug
      hide_word_completion
      false # Rimuove il timer dopo l'esecuzione
    end
  
  end
  
  def apply_completion(suggestion, current_word)
    buffer = @text.buffer

    # Trova la posizione corrente
    end_iter = buffer.get_iter_at(offset: buffer.cursor_position)
    start_iter = end_iter.dup
  
    # Torna indietro all'inizio della parola
    start_iter.backward_word_start

    buffer.begin_user_action
    buffer.delete(start_iter, end_iter)
    buffer.insert(start_iter, suggestion)
    buffer.end_user_action
  
    puts "Completato '#{current_word}' con '#{suggestion}'"  # ← DEBUG
  end

  def hide_word_completion
 
   if @completion_timeout_id
      GLib::Source.remove(@completion_timeout_id)
      @completion_timeout_id = nil
   end
 
   return unless @word_completion_popover

    begin
      @word_completion_popover.popdown      # ← Chiude animato
      @word_completion_popover.unparent     # ← Rilascia risorse
    rescue StandardError => e
      puts "Errore chiusura completion popover: #{e.message}"
    ensure
      @word_completion_popover = nil        # ← Sempre pulito
      @word_completion_listbox = nil        # ← Pulisce anche listbox
      @word_completion_active = false       # ← Reset flag
    end
  end
  
end

class SoundPlayer
  def initialize(sound_file)
    @sound = Gosu::Sample.new(sound_file)
  rescue StandardError => e
    puts "Failed to load sound: #{e.message}"
    @sound = nil
  end

   def play_sound
    @sound&.play
  end
end

Wordprocessor.new
