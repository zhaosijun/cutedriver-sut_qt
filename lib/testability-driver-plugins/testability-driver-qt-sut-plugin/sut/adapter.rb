############################################################################
## 
## Copyright (C) 2010 Nokia Corporation and/or its subsidiary(-ies). 
## All rights reserved. 
## Contact: Nokia Corporation (testabilitydriver@nokia.com) 
## 
## This file is part of TDriver. 
## 
## If you have questions regarding the use of this file, please contact 
## Nokia at testabilitydriver@nokia.com . 
## 
## This library is free software; you can redistribute it and/or 
## modify it under the terms of the GNU Lesser General Public 
## License version 2.1 as published by the Free Software Foundation 
## and appearing in the file LICENSE.LGPL included in the packaging 
## of this file. 
## 
############################################################################

module MobyController

  module QT
    
    # Sut adapter that used TCP/IP connections to send and receive data from QT side. 
    class SutAdapter < MobyController::SutAdapter
      
      attr_reader(
        :sut_id,
        :socket_received_bytes,
        :socket_sent_bytes,
        :socket_received_packets,
        :socket_sent_packets
      )

      attr_accessor(
        :socket_read_timeout,
        :socket_write_timeout
      )
      
      # TODO: better way to set the host and port parameters   
      # Initialize the tcp adapter for communicating with the device.
      # Communication is done using two tcp channels one form commanding
      # the device and one for receiving ui state data.
      # UI state data receivin is done in a seprate thread so it is good
      # once usage is complete the shutdown_comms is called
      # == params
      # sut_id id for the sut so that client details can be fetched from params
      def initialize( sut_id, receive_timeout = 25, send_timeout = 25 )

        @socket = nil
        @connected = false

        @socket_received_bytes = 0
        @socket_sent_bytes = 0

        @socket_received_packets = 0
        @socket_sent_packets = 0

        @sut_id = sut_id

        # set timeouts
        @socket_read_timeout = receive_timeout
        @socket_write_timeout = send_timeout


        @counter = rand( 1000 )

        # connect socket
        #connect( @sut_id )

      end

      # TODO: document me
      def disconnect

        @socket.close if @connected

        @connected = false

      end

      # TODO: document me
      def connect( id = nil )

        id ||= @sut_id

        begin

          @socket = TCPSocket.open( $parameters[ id ][ :qttas_server_ip ], $parameters[ id ][ :qttas_server_port ].to_i )

        rescue => ex

          ip = "no ip" if ( ip = $parameters[ id ][ :qttas_server_ip, "" ] ).empty?
          port = "no port" if ( port = $parameters[ id ][ :qttas_server_port, "" ] ).empty?

          Kernel::raise IOError.new("Unable to connect QTTAS server, verify that it is running properly (#{ ip }:#{ port }): .\nException: #{ ex.message }")
        end

        @connected = true

      end

      # TODO: document me
      def group?

        @_group

      end

      # Set the document builder for the grouped behaviour message.
      def set_message_builder(builder)

        @_group = true

        @_builder = builder

      end

      # TODO: document me
      def append_command(node_list)

        node_list.each {|ch| @_builder.doc.root.add_child(ch)}          

      end

      # Sends a grouped command message to the server. Sets group to false and nils the builder
      # to prevent future behviours of being grouped (unless so wanted)
      # == returns    
      # the amout of commands grouped (and send)
      def send_grouped_request

        @_group = false

        size = @_builder.doc.root.children.size

        send_service_request(Comms::MessageGenerator.generate(@_builder.to_xml))

        @_builder = nil

        size

      end

      # Send the message to the qt server         
      # If there is no exception propagated the send to the device was successful
      # == params   
      # message:: message in qttas protocol format   
      # == returns    
      # the response body
      def send_service_request( message, return_crc = false )

        connect if !@connected        

        # set request message id
        message.message_id = ( @counter += 1 )

        # write request message to socket
        write_socket( message.make_binary_message( @counter ) )

        # read response to determine was the message handled properly and parse the header
        # header[ 0 ] = command_flag
        # header[ 1 ] = body_size
        # header[ 2 ] = crc
        # header[ 3 ] = compression_flag
        # header[ 4 ] = message_id

        header = nil

        body = nil

        read_message_id = 0

        until read_message_id == @counter
        
          header = read_socket( 12 ).unpack( 'CISCI' )

          body = read_socket( header[ 1 ] )

          # read the message body and compare crc checksum
          Kernel::raise IOError, "CRC do not match, response message body may be corrupted!" if CRC::Crc16.crc16_ibm( body, 0xffff ) != header[ 2 ]
          
          # validate response message; check that response message id matches the request
          # if smaller than expected try to read the next message but if bigger raise error
          read_message_id = header[ 4 ]

          if read_message_id < @counter

            $logger.log "warning", "Response to request did not match: \"#{ header[ 4 ].to_s }\"<\"#{ @counter.to_s }\""

          elsif read_message_id > @counter

            $logger.log "fatal", "Response to request did not match: \"#{ header[ 4 ].to_s }\">\"#{ @counter.to_s }\""

            # save to file?
            $logger.log "fatal", body

            Kernel::raise RuntimeError.new( "Response to request did not match: \"#{ header[ 4 ].to_s }\"!=\"#{ @counter.to_s }\"" )

          end
          
        end
      
        # inflate the message body if compressed
        if ( header[ 3 ] == 2 )

		  if $parameters[ @sut_id ][ :win_native, false ] == "true"
			zstream = Zlib::Inflate.new(-Zlib::MAX_WBITS)			
			body = zstream.inflate(body) unless body.empty?
		  else
			# remove leading 4 bytes		  
			body = body[ 4 .. -1 ] 
			body = Zlib::Inflate.inflate( body ) unless body.empty?
		  end

        end

        # raise exception if messages error flag is set
        # Flag statuses:
        #   0 -> ERROR_MSG
        #   1 -> VALID_MSG
        #   2 -> OK_MESSAGE
        if header[ 0 ] == 0

          if body =~ /The application with Id \d+ is no longer available/

            Kernel::raise MobyBase::ApplicationNotAvailableError, body

          else

            Kernel::raise RuntimeError, body

          end

        end

        # return the body ( and crc if required )
        return_crc ? [ body, header[ 2 ] ] : body

      end

    private

      # TODO: document me
      def read_socket( bytes_count )

        # store time before start receving data
        start_time = Time.now

        # verify that there is data available to be read 
        Kernel::raise IOError.new( "Socket reading timeout (%i) exceeded for %i bytes" % [ @socket_read_timeout, bytes_count ] ) if TCPSocket::select( [ @socket ], nil, nil, @socket_read_timeout ).nil?

        # read data from socket
        read_buffer = @socket.read( bytes_count ){

          Kernel::raise IOError.new( "Socket reading timeout (%i) exceeded for %i bytes" % [ @socket_read_timeout, bytes_count ] ) if ( Time.now - start_time ) > @socket_read_timeout

        }

        # useless?
        Kernel::raise IOError.new( "Socket reading error for %i bytes - No data retrieved" % [ bytes_count ] ) if read_buffer.nil?

        @socket_received_bytes += read_buffer.size

        @socket_received_packets += 1

        read_buffer
        
=begin
        begin

          read_buffer = @socket.read_nonblock( bytes_count )

        rescue Errno::EWOULDBLOCK

          if TCPSocket.select( [ @socket ], nil, nil, @socket_read_timeout )

            read_buffer = @socket.read_nonblock( bytes_count )

          else

            Kernel::raise IOError.new( "Socket reading timeout (%i) exceeded for %i bytes" % [ @socket_read_timeout, bytes_count ] )

          end

        end

        read_buffer
=end

=begin
        #Kernel::raise ThreadError, "Timeout within critical session" if Thread.critical

        begin

          # store current thread
          main_thread = Thread.current

          # create timeout thread
          timeout_thread = Thread.new( @socket_read_timeout ){ | timeout, bytes_count |

            # sleep the timeout
            sleep time

            # raise exception if timeout exceeds
            main_thread.raise IOError.new( "Socket reading timeout (%i) exceeded for %i bytes" % [ timeout, bytes_count ] ) if main_thread.alive?

          }
          
          # read data from socket          
          @socket.read( bytes_count )

        ensure

          # ensure that timeout thread is terminated
          timeout_thread.kill if timeout_thread && timeout_thread.alive?

          @socket_received_bytes += bytes_count 

        end
=end

      end

      # TODO: document me
      def write_socket( data )

        @socket_sent_bytes += data.size

        @socket_sent_packets += 1

        @socket.write( data )

        # verify that there is no data in writing buffer 
        Kernel::raise IOError.new( "Socket writing timeout (%i) exceeded for %i bytes" % [ @socket_write_timeout, data.length ] ) if TCPSocket::select( nil, [ @socket ], nil, @socket_write_timeout ).nil?
 
=begin

        begin
          
          # store current thread
          main_thread = Thread.current

          # create timeout thread
          timeout_thread = Thread.new( @socket_write_timeout ){ | timeout, data.size |

            # sleep the timeout
            sleep time

            # raise exception if timeout exceeds
            main_thread.raise IOError.new( "Socket writing timeout (%i) exceeded for %i bytes" % [ timeout, bytes_count ] ) if main_thread.alive?

          }

          # read data from socket          
          @socket.write( data )

        ensure

          # ensure that timeout thread is terminated
          timeout_thread.kill if timeout_thread and timeout_thread.alive?

          @socket_sent_bytes += data.size

        end

=end

      end

      # enable hooking for performance measurement & debug logging
      TDriver::Hooking.hook_methods( self ) if defined?( TDriver::Hooking )

    end # SutAdapter

  end # QT

end # MobyController
