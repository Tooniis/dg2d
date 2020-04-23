/*
  Copyright Chris Jones 2020.
  Distributed under the Boost Software License, Version 1.0.
  See accompanying file Licence.txt or copy at...
  https://www.boost.org/LICENSE_1_0.txt
*/

module dg2d.gradient;

import dg2d.misc;

/*
  Gradient class, 
  The gradient is defined as a list of colours and positions (known as stops) along
  a single dimension from 0 to 1. 
  It has a precomputed lookup table for the rasterizer, currently fixed at 256
  entries. Its a "just get it working for now" solution tbh
*/

class Gradient
{
    // colour is 32 bit ARGB, pos runs from 0..1 

    struct ColorStop
    {
        uint  color;
        float pos;
    }

    size_t length()
    {
        return m_stops.length;
    }

    bool hasChanged()
    {
        return m_changed;
    }

    void reset()
    {
        m_stops.reset();
        m_changed = true;
    }

    Gradient addStop(float pos, uint color)
    {
        m_stops.append(ColorStop(color,clip(pos,0.0,1.0)));
        return this;
    }

    uint[] getLookup()
    {
        if (m_changed) initLookup();
        return m_lookup[0..lookupLen];
    }

    int lutLength()
    {
        return lookupLen;
    }
    
private:
    
    // fixed size lookup for now, could probably have lookup tables cached
    // by the rasterizer rather than stuck in here/

    enum lookupLen = 256;

    void initLookup()
    {
        import std.algorithm : sort;
        m_stops[].sort!("a.pos < b.pos")();
        
        if (m_stops.length == 0)
        {
            foreach(ref c; m_lookup) c = 0;
        }
        else if (m_stops.length == 1)
        {
            foreach(ref c; m_lookup) c = m_stops[0].color;
        }
        else
        {           
            int idx = cast(int) (m_stops[0].pos*256);
            m_lookup[0..idx] = m_stops[0].color;

            foreach(size_t i; 1.. m_stops.length)
            {
                int next = cast(int) (m_stops[i].pos*256);

                foreach(int j; idx..next)
                {
                    uint a = (256*(j-idx))/(next-idx);
                    uint c0 = m_stops[i-1].color;
                    uint c1 = m_stops[i].color;
                    uint t0 = (c0 & 0xFF00FF)*(256-a) + (c1 & 0xFF00FF)*a;
                    uint t1 = ((c0 >> 8) & 0xFF00FF)*(256-a) + ((c1 >> 8) & 0xFF00FF)*a;
                    m_lookup[j] = ((t0 >> 8) & 0xFF00FF) | (t1 & 0xFF00FF00);
                }
                idx = next;
            }
            m_lookup[idx..$] = m_stops[$-1].color;
        }
        m_changed = false;
    }

    Array!(ColorStop,true) m_stops;
    uint[lookupLen] m_lookup;
    bool m_changed = true;
}

