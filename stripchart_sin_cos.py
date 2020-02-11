import numpy as np
import matplotlib.pyplot as plt
import matplotlib.animation as animation
import sys, time, math
from serial import Serial
from matplotlib import style 
import serial.tools.list_ports
xsize=100
style.use('dark_background')

ser = serial.Serial( 
    port='COM6',
    baudrate=115200,
    parity=serial.PARITY_NONE, 
    stopbits=serial.STOPBITS_TWO, 
    bytesize=serial.EIGHTBITS 
)
ser.isOpen() 
def data_gen():
    t = data_gen.t
    while True:
       t+=1
       val1a=ser.readline()
       val1=(float(val1a))
       print("\n")
       print(val1)
       yield t, val1

def run(data):
    # update the data
    t,y1 = data
    if t>-1:
        xdata.append(t)
        ydata1.append(y1)
        if t>xsize: # Scroll to the left.
            ax.set_xlim(t-xsize, t)
        line1.set_data(xdata, ydata1)
    return line1
def on_close_figure(event):
    sys.exit(0)

data_gen.t = -1
fig = plt.figure()
fig.canvas.mpl_connect('close_event', on_close_figure)
ax = fig.add_subplot(111)
line1, = ax.plot([], [], lw=2, label='°Celsius')
ax.set_ylim(20, 250)
ax.set_xlim(0, xsize)
ax.xaxis.label.set_color('c')
ax.yaxis.label.set_color('c')
plt.title("Project 1 Temperature Graph\n(°C/s)")
plt.xlabel('Time (seconds)')
plt.ylabel('Temperature (°Celsius)')
ax.grid()
ax.legend()
xdata, ydata1 = [], []

# Important: Although blit=True makes graphing faster, we need blit=False to prevent
# spurious lines to appear when resizing the stripchart.
ani = animation.FuncAnimation(fig, run, data_gen, blit=False, interval=100, repeat=False)
plt.show()
