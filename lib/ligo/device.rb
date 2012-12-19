# -*- coding: utf-8; fill-column: 80 -*-
#
# Copyright (c) 2012 Renaud AUBIN
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

module Ligo

  require 'ligo/constants'

  class Device < LIBUSB::Device
    include Logging

    # TODO: Document the attr!
    attr_reader :pDev, :pDevDesc
    attr_reader :aoap_version, :accessory, :in, :out, :handle

    def initialize context, pDev
      @aoap_version = 0
      @accessory, @in, @out, @handle = nil, nil, nil, nil
      super context, pDev
    end

    def process(&block)
      begin
        self.open_interface(0) do |handle|
          @handle = handle
          yield handle
          @handle = nil
        end
        # close
      rescue LIBUSB::ERROR_NO_DEVICE
        msg =  'The target device has been disconnected'
        logger.debug msg
        # close
        raise Interrupt, msg
      end
    end

    # Simple write method (blocking until timeout).
    # @param [Fixnum] buffer_size
    #   The number of bytes expected to be received.
    # @param [Fixnum] timeout
    #   The timeout in ms (default: 1000). 0 for an infinite timeout.
    # @return [String] the received buffer (at most buffer_size bytes).
    # @raise [LIBUSB::ERROR_TIMEOUT] in case of timeout.
    def read(buffer_size, timeout = 1000)
      handle.bulk_transfer(endpoint: @in,
                           dataIn: buffer_size,
                           timeout: timeout)
    end

    # Simple write method (blocking until timeout).
    # @param [String] buffer
    #   The buffer to be sent.
    # @param [Fixnum] timeout
    #   The timeout in ms (default: 1000). 0 for an infinite timeout.
    # @return [Fixnum] the number of bytes actually sent.
    # @raise [LIBUSB::ERROR_TIMEOUT] in case of timeout.
    def write(buffer, timeout = 1000)
        handle.bulk_transfer(endpoint: @in,
                             dataOut: buffer,
                             timeout: timeout)
    end

    # Simple recv method.
    # @param [Fixnum] buffer_size
    #   The buffer size of the received buffer.
    # @return [String] the received buffer (at most buffer_size bytes).
    def recv(buffer_size)
      begin
        handle.bulk_transfer(endpoint: @in,
                             dataIn: buffer_size)
      rescue LIBUSB::ERROR_TIMEOUT
        nil
        # maybe we should implement a internal thread, a sleep and a retry
      end
    end

    # Simple send method.
    # @param [String] data
    #   The data to be sent.
    # @return [Fixnum] the number of bytes sent.
    def send(data)
      # TODO: Add timeout param?
      handle.bulk_transfer(endpoint: @out, dataOut: data)
    end

    # Associate an AOAP compatible device with a virtual accessory and switch the Android device
    # to accessory mode.
    #
    # Prepare an OAP compatible device to interact with a given {Ligo::Accessory}:
    # * Switch the current assigned device to accessory mode
    # * Set the I/O endpoints
    # @param [Ligo::Accessory] accessory
    #   The virtual accessory to be associated with the Android device.
    # @return [true, false] true for success, false otherwise.
    def attach_accessory(accessory)
      logger.debug "attach_accessory(#{accessory})"

      @accessory = accessory

      if accessory_mode?
        # if the device is already in accessory mode, we send
        # set_configuration to force an usb attached event on the device
        begin
          set_configuration
        rescue LIBUSB::ERROR_NO_DEVICE
          logger.debug '  set_configuration raises LIBUSB::ERROR_NO_DEVICE - Retry'
          sleep REENUMERATION_DELAY
          # Set configuration may fail
          retry
        end
      else
        # the device is not in accessory mode, start_accessory_mode is
        # sufficient to get an usb attached event on the device
        return false unless start_accessory_mode
      end

      # Find out the in/out endpoints
      self.interfaces.first.endpoints.each do |ep|
        if ep.bEndpointAddress & 0b10000000 == 0
          @out = ep if @out.nil?
        else
          @in = ep if @in.nil?
        end
      end
      true
    end

    # Send identifying string information to the device and request the device start up in accessory
    # mode.
    def start_accessory_mode
      logger.debug 'start_accessory_mode'
      sn = self.serial_number

      self.open_interface(0) do |handle|
        @handle = handle
        send_accessory_id
        send_start
        @handle = nil
      end

      wait_and_retrieve_by_serial(sn)
    end

    # Set the device's configuration to a value of 1 with a SET_CONFIGURATION (0x09) device
    # request.
    # @return [true, false] true for success, false otherwise.
    def set_configuration
      logger.debug 'set_configuration'
      res = nil
      sn = self.serial_number
      device = @context.devices(idVendor: GOOGLE_VID).collect do |d|
        d.serial_number == sn ? d : nil
      end.compact.first

      begin
        device.open_interface(0) do |handle|
          req_type = LIBUSB::ENDPOINT_OUT | LIBUSB::REQUEST_TYPE_STANDARD
          res = handle.control_transfer(bmRequestType: req_type,
                                        bRequest: LIBUSB::REQUEST_SET_CONFIGURATION,
                                        wValue: 1, wIndex: 0x0, dataOut: nil)
        end

        wait_and_retrieve_by_serial(sn)
        res == 0
      end
    end

    # Check if the current {Ligo::Device} is in accessory mode.
    # @return [true, false] true if the {Ligo::Device} is in accessory mode,
    #   false otherwise.
    def accessory_mode?
      self.idVendor == GOOGLE_VID
    end

    # Check if the current {Ligo::Device} supports AOAP.
    # @return [true, false] true if the {Ligo::Device} supports AOAP, false
    #   otherwise.
    def aoap?
      @aoap_version = self.get_protocol
      logger.info "#{self.inspect} supports AOAP version #{@aoap_version}."
      @aoap_version >= 1
    end

    # Check if the current {Ligo::Device} is in UMS mode.
    # @return [true, false] true if the {Ligo::Device} is in UMS mode, false
    #   otherwise.
    def uas?
      if RUBY_PLATFORM=~/linux/i
        # http://cateee.net/lkddb/web-lkddb/USB_UAS.html
        (self.settings[0].bInterfaceClass == 0x08) &&
          (self.settings[0].bInterfaceSubClass == 0x06)
      else
        false
      end
    end

    # Send a 51 control request ("Get Protocol") to figure out if the device
    # supports the Android accessory protocol.
    # @return [Fixnum] the AOAP protocol version supported by the device (0 for
    #   no AOAP support).
    def get_protocol
      logger.debug 'get_protocol'
      res, version = 0, 0
      self.open do |h|

        h.detach_kernel_driver(0) if self.uas? && h.kernel_driver_active?(0)
        req_type = LIBUSB::ENDPOINT_IN | LIBUSB::REQUEST_TYPE_VENDOR
        res = h.control_transfer(bmRequestType: req_type,
                                 bRequest: COMMAND_GETPROTOCOL,
                                 wValue: 0x0, wIndex: 0x0, dataIn: 2)

        version = res.unpack('S')[0]
      end

      (res.size == 2 && version >= 1 ) ? version : 0
    end

    # Send identifying string information to the device.
    def send_accessory_id
      logger.debug 'send_accessory_id'
      req_type = LIBUSB::ENDPOINT_OUT | LIBUSB::REQUEST_TYPE_VENDOR
      @accessory.each do |k,v|
        # Ensure the string is terminated by a null char
        s = "#{v}\0"
        r = @handle.control_transfer(bmRequestType: req_type,
                                     bRequest: COMMAND_SENDSTRING, wValue: 0x0,
                                     wIndex: @accessory.keys.index(k), dataOut: s)

        # TODO: Manage an exception there. This should terminate the program.
        logger.error "Failed to send #{k} string" unless r == s.size
      end
    end
    private :send_accessory_id

    # Request the device start up in accessory mode
    def send_start
      logger.debug 'send_start'
      req_type = LIBUSB::ENDPOINT_OUT | LIBUSB::REQUEST_TYPE_VENDOR
      res = @handle.control_transfer(bmRequestType: req_type,
                                     bRequest: COMMAND_START, wValue: 0x0,
                                     wIndex: 0x0, dataOut: nil)
    end
    private :send_start

    # Internal use only.
    def wait_and_retrieve_by_serial(sn)
      sleep REENUMERATION_DELAY
      # The device should now reappear on the usb bus with the Google vendor id.
      # We retrieve it by using its serial number.
      device = @context.devices(idVendor: GOOGLE_VID).collect do |d|
        d.serial_number == sn ? d : nil
      end.compact.first

      if device
        # Retrieve new pointers (check if the old ones should be dereferenced)
        @pDev = device.pDev
        @pDevDesc = device.pDevDesc
      else
        logger.error ['Failed to retrieve the device after switching to ',
                      'accessory mode. This may be due to a lack of proper ',
                      'permissions ⇒ check your udev rules.', "\n",
                      'The Google vendor id rule may look like:', "\n",
                      'SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ',
                      'MODE="0666", GROUP="plugdev"'
                     ].join
      end
    end
    private :wait_and_retrieve_by_serial

  end

end
