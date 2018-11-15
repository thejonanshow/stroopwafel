require 'dotenv/load'
require "json"
require "ruby-kafka"
require "wemote"
require "rpi_gpio"

class Stroopwafel
  RECIPE = {
    open_lid: ["Opening lid...", "yellow"],
    deploy_dispenser: ["Deploying dispenser...", "yellow"],
    dispense: ["Dispensing batter...", "green"],
    retract_dispenser: ["Retracting dispenser...", "blue"],
    close_lid: ["Closing lid...", "blue"],
    flip_iron: ["Flipping waffle...", "yellow"],
    cooking_timer: ["Cooking...", "red"],
    flip_iron_back: ["Flipping waffle...", "blue"],
    finish: ["Opening lid...", "yellow"]
  }

  def initialize
    @beeped = false
    @booted = false
    @shutdown_timer = nil

    @working_recipe = RECIPE.dup

    @waffle_iron_switch = Wemote::Switch.find('waffle_iron')
    @usb_switch = Wemote::Switch.find('usb_hub')
    @control_switch = Wemote::Switch.find('control')

    @kafka = Kafka.new(
      ENV['KAFKA_URL'],
      ssl_ca_cert: ENV['KAFKA_TRUSTED_CERT'],
      ssl_client_cert: ENV['KAFKA_CLIENT_CERT'],
      ssl_client_cert_key: ENV['KAFKA_CLIENT_CERT_KEY']
    )

    @kafka.each_message(topic: "pendoreille-6647.wafflebot") do |message|
      action = JSON.parse(message.value)["message"]
      puts "Stroopwafel Received #{action}"

      if action.match /_done$/
        self.send(action) if respond_to? action
      elsif action == "start"
        start
      elsif @working_recipe.length > 0
        cook
      else
        reset
      end
    end
  end

  def reset_done
    @working_recipe = RECIPE.dup
    speak_ui("Resetting...", "gray")
    sleep 25
    speak_ui("go_home", "gray")
  end

  def check_beep_done
    @beeped = true
    enable_control if @booted
  end

  def check_boot_done
    @booted = true
    enable_control if @beeped
  end

  def cook
    action, message = @working_recipe.shift
    speak_chef(action)
    status, color = message
    speak_ui(status, color)
  end

  def speak_ui(message, color)
    data = { message: message, color: color }.to_json
    @kafka.deliver_message(data, topic: "pendoreille-6647.wafflebotui")
  end

  def speak_chef(message)
    data = { message: message }.to_json
    @kafka.deliver_message(data, topic: "pendoreille-6647.wafflechef")
  end

  def start
    cook
    return

    @shutdown_timer.kill if @shutdown_timer
    @shutdown_timer = nil

    enable_waffle_iron
    speak_ui("Heating iron...", "red")
    sleep 5

    enable_usb_hub
    speak_ui("Booting...", "green")
    sleep 15

    speak_chef("check_boot")
    speak_chef("check_beep")
  end

  def enable_waffle_iron
    return if @waffle_iron_switch.on?
    @waffle_iron_switch.on!
  end

  def enable_usb_hub
    return if @usb_switch.on?
    @usb_switch.on!
  end

  def enable_control
    return if @control_switch.on?
    speak_ui("Powering up...", "green")
    sleep 5
    cook
  end

  def shutdown
    @waffle_iron_switch.off!
    @control_switch.off!
    speak_chef("shutdown")
  end

  def shutdown_done
    sleep 10
    @beeped = false
    @booted = false
    @usb_switch.off!
  end

  def reset
    speak_chef("reset")
    return

    @shutdown_timer = Thread.new do
      sleep 220
      shutdown
    end
  end
end

class WaffleChef
  attr_reader :beeper, :swing, :lift, :valve, :pump, :flip

  def initialize
    @beeper = Beeper.new(16)
    @swing = Motor.new(6, 5, 0.0005)
    @lift = Motor.new(19, 13, 0.0005)
    @valve = Switch.new(14)
    @pump = Switch.new(15)
    @flip = Motor.new(21, 20, 0.00005)

    RPi::GPIO.setup 26, as: :output
    RPi::GPIO.set_low 26

    @kafka = Kafka.new(
      ENV['KAFKA_URL'],
      ssl_ca_cert: ENV['KAFKA_TRUSTED_CERT'],
      ssl_client_cert: ENV['KAFKA_CLIENT_CERT'],
      ssl_client_cert_key: ENV['KAFKA_CLIENT_CERT_KEY']
    )

    @kafka.each_message(topic: "pendoreille-6647.wafflechef") do |message|
      action = JSON.parse(message.value)["message"]
      puts "WaffleChef Received #{action}"

      self.send(action) if respond_to? action
      speak_stroop("#{action}_done")
    end
  end

  def shutdown
    speak_stroop("shutdown_done")
    `shutdown now`
  end

  def cooking_timer
    sleep 420
  end

  def reset
    sleep 180
    close_lid
  end

  def check_beep
    @beeper.wait
  end

  def speak_stroop(message)
    data = { message: message }.to_json
    @kafka.deliver_message(data, topic: "pendoreille-6647.wafflebot")
  end

  def open_lid
    @lift.forward(800)
    sleep 25
  end

  def close_lid
    @lift.forward(800)
    sleep 25
  end

  def deploy_dispenser
    @swing.forward(5500)
    sleep 7
  end

  def retract_dispenser
    @swing.backward(5500)
    sleep 7
  end

  def dispense
    @valve.on
    @pump.on
    sleep 7
    @pump.off
    @valve.off
  end

  def flip_iron
    @flip.forward(42000)
    sleep 10
  end

  def flip_iron_back
    @flip.backward(42000)
    sleep 10
  end

  def finish
    @lift.forward(800)
    sleep 10
    `omxplayer zelda.mp3`
  end
end

class Switch
  def initialize(pin)
    RPi::GPIO.set_numbering :bcm

    @pin = pin
    RPi::GPIO.setup @pin, :as => :output

    off
  end

  def on
    RPi::GPIO.set_high @pin
  end

  def off
    RPi::GPIO.set_low @pin
  end
end

class Beeper
  def initialize(pin)
    RPi::GPIO.set_numbering :bcm
    @pin = pin
    RPi::GPIO.setup @pin, as: :input, pull: :down
  end

  def wait
    timeout = 180
    while (timeout > 0) && (RPi::GPIO.low? @pin)
      sleep 1
      timeout -= 1
    end
  end
end

class Motor
  def initialize(step_pin, reverse_pin, delay)
    RPi::GPIO.set_numbering :bcm

    @step_pin = step_pin
    @reverse_pin = reverse_pin
    @delay = delay
  end

  def forward(steps)
    RPi::GPIO.setup @step_pin, :as => :output

    steps.times do
      RPi::GPIO.set_high @step_pin
      sleep @delay
      RPi::GPIO.set_low @step_pin
      sleep @delay
    end
  end

  def backward(steps)
    RPi::GPIO.setup @step_pin, :as => :output
    RPi::GPIO.setup @reverse_pin, :as => :output

    RPi::GPIO.set_high @reverse_pin
    forward(steps)
  ensure
    RPi::GPIO.set_low @reverse_pin
  end
end
