/*
  Copyright Chris Jones 2020.
  Distributed under the Boost Software License, Version 1.0.
  See accompanying file Licence.txt or copy at...
  https://www.boost.org/LICENSE_1_0.txt
*/

module linearblit;

import rasterizer;
import gradient;
import misc;

/*
  linear gradient blit
*/

struct LinearBlit
{   
    void init(uint* pixels, int stride, int height,
              Gradient g, float x0, float y0, float x1, float y1)
    {
        assert(((cast(int)pixels) & 15) == 0); // must be 16 byte alligned
        assert((stride & 3) == 0);             // stride must be 16 byte alligned
        assert(height > 0);
        assert(g !is null);
        assert(isPow2(g.lutLength));

        this.pixels = pixels;
        this.stride = stride;
        this.height = height;
        this.gradient = g;
        int lutsize = g.lutLength;

        xctr = x0;
        yctr = y0;
        float w = x1-x0;
        float h = y1-y0;
        float hsq = w*w + h*h;
        if (hsq < 0.1) hsq = 0.1; // avoid div by zero
        xstep = lutsize * w / hsq; 
        ystep = lutsize * h / hsq;
    }

    Blitter getBlitter(WindingRule wr)
    {
        if (wr == WindingRule.NonZero)
        {
            return &linear_blit!(WindingRule.NonZero);
        }
        else
        {
            return &linear_blit!(WindingRule.EvenOdd);
        }
    }

private:

    void linear_blit(WindingRule wr)(int* delta, DMWord* mask, int x0, int x1, int y)
    {
        assert( ( cast(size_t)delta & 15 ) == 0 );
        assert(x0 >= 0);
        assert(x1 <= stride);
        assert(y >= 0);
        assert(y < height);
        assert((x0 & 3) == 0);
        assert((x1 & 3) == 0);

        // main blit variables

        int bpos = x0 / 4;
        int endbit = x1 / 4;
        uint* dest = &pixels[y*stride];
        __m128i xmWinding = 0;
        uint* lut = gradient.getLookup.ptr;
        uint lutmsk = gradient.lutLength - 1;
        bool isopaque = false;//gradient.isOpaque

        // XMM constants

        immutable __m128i XMZERO = 0;
        immutable __m128i XMFFFF = [0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF];
        immutable __m128i XMMSK16 = [0xFFFF,0xFFFF,0xFFFF,0xFFFF];

        // paint variables

        float t0 = (bpos*4-xctr)*xstep + (y-yctr)*ystep;
        __m128 xmT0 = _mm_mul_ps(_mm_set1_ps(xstep), _mm_setr_ps(0.0f,1.0f,2.0f,3.0f));
        xmT0 = _mm_add_ps(xmT0, _mm_set1_ps(t0));
        __m128 xmStep0 = _mm_set1_ps(xstep*4);

        // main loop

        while (bpos < endbit)
        {
            int nsb = nextSetBit(mask, bpos, endbit);

            // do we have a span of unchanging coverage?

            if (bpos < nsb)
            {
                // Calc coverage of first pixel

                static if (wr == WindingRule.NonZero)
                {
                    int cover = xmWinding[3]+delta[bpos*4];
                    cover = abs(cover)*2;
                    if (cover > 0xFFFF) cover = 0xFFFF;
                }
                else
                {
                    int cover = xmWinding[3]+delta[bpos*4];
                    short tsc = cast(short) cover;
                    cover = (tsc ^ (tsc >> 15)) * 2;
                }

                // We can skip the span

                if (cover == 0)
                {
                    __m128 tsl = _mm_set1_ps(nsb-bpos);
                    xmT0 = _mm_add_ps(xmT0, _mm_mul_ps(tsl,xmStep0));
                    bpos = nsb;
                }

                // Or fill span with soid color

                else if (isopaque && (cover > 0xFF00))
                {
                    uint* ptr = &dest[bpos*4];
                    uint* end = ptr + ((nsb-bpos)*4);

                    while (ptr < end)
                    {
                        __m128i ipos = _mm_cvtps_epi32 (xmT0);
                        xmT0 = xmT0 + xmStep0;

                        long tlip = _mm_cvtsi128_si64 (ipos);
                        ipos = _mm_shuffle_epi32!14(ipos);
                        ptr[0] = lut[tlip & lutmsk];
                        ptr[1] = lut[(tlip >> 32) & lutmsk];
                        tlip = _mm_cvtsi128_si64 (ipos);
                        ptr[2] = lut[tlip & lutmsk];
                        ptr[3] = lut[(tlip >> 32) & lutmsk];

                        ptr+=4;                        
                    }

                    bpos = nsb;
                }

                // Or fill span with transparent color

                else
                {
                    __m128i tqcvr = _mm_set1_epi16 (cast(ushort) cover);

                    uint* ptr = &dest[bpos*4];
                    uint* end = &dest[nsb*4];

                    while (ptr < end)
                    {
                        __m128i ipos = _mm_cvtps_epi32 (xmT0);
                        xmT0 = xmT0 + xmStep0;

                        __m128i d0 = _mm_loadu_si64 (ptr);
                        d0 = _mm_unpacklo_epi8 (d0, XMZERO);
                        __m128i d1 = _mm_loadu_si64 (ptr+2);
                        d1 = _mm_unpacklo_epi8 (d1, XMZERO);

                        long tlip = _mm_cvtsi128_si64 (ipos);
                        ipos = _mm_unpackhi_epi64 (ipos, ipos);

                        __m128i c0 = _mm_loadu_si32 (&lut[tlip & lutmsk]);
                        __m128i tnc = _mm_loadu_si32 (&lut[(tlip >> 32) & lutmsk]);
                        c0 = _mm_unpacklo_epi32 (c0, tnc);
                        c0 = _mm_unpacklo_epi8 (c0, XMZERO);
                        __m128i a0 = _mm_broadcast_alpha(c0);
                        a0 = _mm_mulhi_epu16(a0, tqcvr);

                        tlip = _mm_cvtsi128_si64 (ipos);
                        
                        __m128i c1 = _mm_loadu_si32 (&lut[tlip & lutmsk]);
                        tnc = _mm_loadu_si32 (&lut[(tlip >> 32) & lutmsk]);
                        c1 = _mm_unpacklo_epi32 (c1, tnc);
                        c1 = _mm_unpacklo_epi8 (c1, XMZERO);
                        __m128i a1 = _mm_broadcast_alpha(c1);
                        a1 = _mm_mulhi_epu16(a1, tqcvr);

                       // alpha*source + dest - alpha*dest

                        c0 = _mm_mulhi_epu16 (c0,a0);
                        c1 = _mm_mulhi_epu16 (c1,a1);
                        c0 = _mm_adds_epi16 (c0,d0);
                        c1 = _mm_adds_epi16 (c1,d1);
                        d0 = _mm_mulhi_epu16 (d0,a0);
                        d1 = _mm_mulhi_epu16 (d1,a1);
                        c0 =  _mm_subs_epi16 (c0, d0);
                        c1 =  _mm_subs_epi16 (c1, d1);

                        d0 = _mm_packus_epi16 (c0,c1);

                        _mm_store_si128 (cast(__m128i*)ptr,d0);
                        
                        ptr+=4;
                    }

                    bpos = nsb;
                }
            }

            // At this point we need to integrate scandelta

            uint* ptr = &dest[bpos*4];
            uint* end = &dest[endbit*4];
            int* dlptr = &delta[bpos*4];

            while (bpos < endbit)
            {
                // Integrate delta values

                __m128i tqw = _mm_load_si128(cast(__m128i*)dlptr);
                tqw = _mm_add_epi32(tqw, _mm_slli_si128!4(tqw)); 
                tqw = _mm_add_epi32(tqw, _mm_slli_si128!8(tqw)); 
                tqw = _mm_add_epi32(tqw, xmWinding); 
                xmWinding = _mm_shuffle_epi32!255(tqw);  
                _mm_store_si128(cast(__m128i*)dlptr,XMZERO);

                // Process coverage values taking account of winding rule
                
                static if (wr == WindingRule.NonZero)
                {
                    __m128i tcvr = _mm_srai_epi32(tqw,31); 
                    tqw = _mm_add_epi32(tcvr,tqw);
                    tqw = _mm_xor_si128(tqw,tcvr);         // abs
                    tcvr = _mm_packs_epi32(tqw,XMZERO);    // saturate/pack to int16
                    tcvr = _mm_slli_epi16(tcvr, 1);        // << to uint16
                }
                else
                {
                    __m128i tcvr = _mm_and_si128(tqw,XMMSK16); 
                    tqw = _mm_srai_epi16(tcvr,15);         // mask
                    tcvr = _mm_xor_si128(tcvr,tqw);        // fold in halff
                    tcvr = _mm_packs_epi32(tcvr,XMZERO);   // pack to int16
                    tcvr = _mm_slli_epi16(tcvr, 1);        // << to uint16
                }

                // convert grad pos to integer

                __m128i ipos = _mm_cvtps_epi32 (xmT0);
                xmT0 = xmT0 + xmStep0;

                // Load destination pixels

                __m128i d0 = _mm_loadu_si64 (ptr);
                d0 = _mm_unpacklo_epi8 (d0, XMZERO);
                __m128i d1 = _mm_loadu_si64 (ptr+2);
                d1 = _mm_unpacklo_epi8 (d1, XMZERO);

                // load grad colors

                long tlip = _mm_cvtsi128_si64 (ipos);
                ipos = _mm_unpackhi_epi64 (ipos, ipos);

                tcvr = _mm_unpacklo_epi16 (tcvr, tcvr);
                __m128i tcvr2 = _mm_unpackhi_epi32 (tcvr, tcvr);
                tcvr = _mm_unpacklo_epi32 (tcvr, tcvr);

                __m128i c0 = _mm_loadu_si32 (&lut[tlip & lutmsk]);
                __m128i tnc = _mm_loadu_si32 (&lut[(tlip >> 32) & lutmsk]);
                c0 = _mm_unpacklo_epi32 (c0, tnc);
                c0 = _mm_unpacklo_epi8 (c0, XMZERO);
                __m128i a0 = _mm_broadcast_alpha(c0);
                a0 = _mm_mulhi_epu16(a0, tcvr);

                tlip = _mm_cvtsi128_si64 (ipos);

                __m128i c1 = _mm_loadu_si32 (&lut[tlip & lutmsk]);
                tnc = _mm_loadu_si32 (&lut[(tlip >> 32) & lutmsk]);
                c1 = _mm_unpacklo_epi32 (c1, tnc);
                c1 = _mm_unpacklo_epi8 (c1, XMZERO);
                __m128i a1 = _mm_broadcast_alpha(c1);
                a1 = _mm_mulhi_epu16(a1, tcvr2);

                // alpha*source + dest - alpha*dest

                c0 = _mm_mulhi_epu16 (c0,a0);
                c1 = _mm_mulhi_epu16 (c1,a1);
                c0 = _mm_adds_epi16 (c0,d0);
                c1 = _mm_adds_epi16 (c1,d1);
                d0 = _mm_mulhi_epu16 (d0,a0);
                d1 = _mm_mulhi_epu16 (d1,a1);
                c0 =  _mm_subs_epi16 (c0, d0);
                c1 =  _mm_subs_epi16 (c1, d1);

                d0 = _mm_packus_epi16 (c0,c1);

                _mm_store_si128 (cast(__m128i*)ptr,d0);
                
                bpos++;
                ptr+=4;
                dlptr+=4;

                if (((cast(ulong*)dlptr)[0] | (cast(ulong*)dlptr)[1]) == 0)  break;
            }
        }
    }

    // Member variables

    uint* pixels;
    int stride;
    int height;
    Gradient gradient;
    float xctr,yctr;
    float xstep,ystep;
}


