#include <iostream>
#include <string>
#include <memory>
#include <stdexcept>

extern "C" {
    #include <libavcodec/avcodec.h>
    #include <libavformat/avformat.h>
    #include <libswscale/swscale.h>
    #include <libavutil/imgutils.h>
}

#include <SFML/Graphics.hpp>

class MP4Player {
private:
    AVFormatContext* format_ctx = nullptr;
    AVCodecContext* codec_ctx = nullptr;
    AVFrame* frame = nullptr;
    AVFrame* rgb_frame = nullptr;
    AVPacket* packet = nullptr;
    SwsContext* sws_ctx = nullptr;
    
    int video_stream_index = -1;
    bool eof_reached = false;
    bool initialized = false;
    
    // Buffer for RGB data
    uint8_t* rgb_buffer = nullptr;
    
public:
    MP4Player() = default;
    
    ~MP4Player() {
        cleanup();
    }
    
    bool initialize(const std::string& filename) {
        // Initialize FFmpeg
        avformat_network_init();
        
        // Open video file
        if (avformat_open_input(&format_ctx, filename.c_str(), nullptr, nullptr) != 0) {
            std::cerr << "Error: Could not open file " << filename << std::endl;
            return false;
        }
        
        // Retrieve stream information
        if (avformat_find_stream_info(format_ctx, nullptr) < 0) {
            std::cerr << "Error: Could not find stream information" << std::endl;
            return false;
        }
        
        // Find the first video stream
        for (unsigned int i = 0; i < format_ctx->nb_streams; i++) {
            if (format_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
                video_stream_index = i;
                break;
            }
        }
        
        if (video_stream_index == -1) {
            std::cerr << "Error: Could not find video stream" << std::endl;
            return false;
        }
        
        // Get codec parameters and find decoder
        AVCodecParameters* codec_params = format_ctx->streams[video_stream_index]->codecpar;
        const AVCodec* codec = avcodec_find_decoder(codec_params->codec_id);
        
        if (!codec) {
            std::cerr << "Error: Unsupported codec" << std::endl;
            return false;
        }
        
        // Allocate codec context
        codec_ctx = avcodec_alloc_context3(codec);
        if (!codec_ctx) {
            std::cerr << "Error: Could not allocate codec context" << std::endl;
            return false;
        }
        
        // Copy codec parameters to codec context
        if (avcodec_parameters_to_context(codec_ctx, codec_params) < 0) {
            std::cerr << "Error: Could not copy codec parameters" << std::endl;
            return false;
        }
        
        // Open codec
        if (avcodec_open2(codec_ctx, codec, nullptr) < 0) {
            std::cerr << "Error: Could not open codec" << std::endl;
            return false;
        }
        
        // Allocate frames
        frame = av_frame_alloc();
        rgb_frame = av_frame_alloc();
        packet = av_packet_alloc();
        
        if (!frame || !rgb_frame || !packet) {
            std::cerr << "Error: Could not allocate frames/packet" << std::endl;
            return false;
        }
        
        // Prepare RGB buffer
        int buffer_size = av_image_get_buffer_size(AV_PIX_FMT_RGB24, 
                                                   codec_ctx->width, 
                                                   codec_ctx->height, 
                                                   1);
        rgb_buffer = (uint8_t*)av_malloc(buffer_size * sizeof(uint8_t));
        
        if (!rgb_buffer) {
            std::cerr << "Error: Could not allocate RGB buffer" << std::endl;
            return false;
        }
        
        // Setup RGB frame
        av_image_fill_arrays(rgb_frame->data, rgb_frame->linesize,
                            rgb_buffer, AV_PIX_FMT_RGB24,
                            codec_ctx->width, codec_ctx->height, 1);
        
        // Initialize SWSCALE context for color space conversion
        sws_ctx = sws_getContext(codec_ctx->width, codec_ctx->height, codec_ctx->pix_fmt,
                                 codec_ctx->width, codec_ctx->height, AV_PIX_FMT_RGB24,
                                 SWS_BILINEAR, nullptr, nullptr, nullptr);
        
        if (!sws_ctx) {
            std::cerr << "Error: Could not initialize SWSCALE context" << std::endl;
            return false;
        }
        
        std::cout << "Video loaded: " << filename << std::endl;
        std::cout << "Dimensions: " << codec_ctx->width << "x" << codec_ctx->height << std::endl;
        std::cout << "FPS: " << av_q2d(format_ctx->streams[video_stream_index]->avg_frame_rate) << std::endl;
        
        initialized = true;
        return true;
    }
    
    std::unique_ptr<sf::Texture> getNextFrame() {
        if (!initialized || eof_reached) {
            return nullptr;
        }
        
        bool frame_decoded = false;
        
        while (!frame_decoded) {
            // Read packet from stream
            int ret = av_read_frame(format_ctx, packet);
            
            if (ret < 0) {
                // End of file or error, seek to beginning
                av_seek_frame(format_ctx, video_stream_index, 0, AVSEEK_FLAG_FRAME);
                eof_reached = false;
                continue;
            }
            
            // Check if packet is from video stream
            if (packet->stream_index == video_stream_index) {
                // Send packet to decoder
                ret = avcodec_send_packet(codec_ctx, packet);
                if (ret < 0) {
                    av_packet_unref(packet);
                    continue;
                }
                
                // Receive frame from decoder
                ret = avcodec_receive_frame(codec_ctx, frame);
                if (ret == 0) {
                    frame_decoded = true;
                    
                    // Convert frame to RGB
                    sws_scale(sws_ctx, frame->data, frame->linesize,
                              0, codec_ctx->height,
                              rgb_frame->data, rgb_frame->linesize);
                } else if (ret == AVERROR(EAGAIN)) {
                    // Need more data
                    av_packet_unref(packet);
                    continue;
                }
            }
            
            av_packet_unref(packet);
        }
        
        // Create SFML texture from RGB data
        auto texture = std::make_unique<sf::Texture>();
        if (!texture->resize({codec_ctx->width, codec_ctx->height})) {
            std::cerr << "Error: Could not create SFML texture" << std::endl;
            return nullptr;
        }
        
        texture->update(rgb_buffer);
        return texture;
    }
    
    void reset() {
        if (initialized) {
            av_seek_frame(format_ctx, video_stream_index, 0, AVSEEK_FLAG_FRAME);
            avcodec_flush_buffers(codec_ctx);
            eof_reached = false;
        }
    }
    
    int getWidth() const {
        return initialized ? codec_ctx->width : 0;
    }
    
    int getHeight() const {
        return initialized ? codec_ctx->height : 0;
    }
    
    bool isInitialized() const {
        return initialized;
    }
    
    bool isEof() const {
        return eof_reached;
    }
    
private:
    void cleanup() {
        if (sws_ctx) {
            sws_freeContext(sws_ctx);
            sws_ctx = nullptr;
        }
        
        if (rgb_buffer) {
            av_free(rgb_buffer);
            rgb_buffer = nullptr;
        }
        
        if (frame) {
            av_frame_free(&frame);
        }
        
        if (rgb_frame) {
            av_frame_free(&rgb_frame);
        }
        
        if (packet) {
            av_packet_free(&packet);
        }
        
        if (codec_ctx) {
            avcodec_free_context(&codec_ctx);
        }
        
        if (format_ctx) {
            avformat_close_input(&format_ctx);
        }
        
        avformat_network_deinit();
        
        initialized = false;
        eof_reached = false;
        video_stream_index = -1;
    }
};
